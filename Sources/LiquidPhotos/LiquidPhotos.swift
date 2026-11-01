//
//  LiquidPhotos.swift
//  LiquidPhotos
//
//  A photo stage where each photo melts into the next: the camera glides
//  from one subject to the other, the frame reshapes to the new photo, and
//  the pictures flow into each other through a soft defocus.
//
//      LiquidPhotos(photos, selection: $index, isPlaying: $playing)
//

import MetalKit
import SwiftUI

/// How a `LiquidPhotos` stage moves.
public struct LiquidPhotosStyle: Equatable, Sendable {
    /// Seconds one transition takes.
    public var transitionDuration: Double = 1.6
    /// Seconds each photo holds while playing.
    public var holdDuration: Double = 1.8
    /// Playback starts over after the last photo.
    public var loops = true
    /// How far the pictures flow into each other (0 dissolves in place).
    public var morph: Double = 1
    /// How soft the middle of a transition gets (0 stays sharp).
    public var defocus: Double = 1
    /// How far the camera pushes in through a transition.
    public var push: Double = 1
    /// A resting photo drifts slowly toward its subject, like a live photo.
    public var drift = true
    /// The photo frame's corner radius.
    public var cornerRadius: CGFloat = 0

    public init(
        transitionDuration: Double = 1.6,
        holdDuration: Double = 1.8,
        loops: Bool = true,
        morph: Double = 1,
        defocus: Double = 1,
        push: Double = 1,
        drift: Bool = true,
        cornerRadius: CGFloat = 0
    ) {
        self.transitionDuration = transitionDuration
        self.holdDuration = holdDuration
        self.loops = loops
        self.morph = morph
        self.defocus = defocus
        self.push = push
        self.drift = drift
        self.cornerRadius = cornerRadius
    }
}

/// Shows one photo at a time, full width and at its own shape, and morphs
/// into the next whenever `selection` changes or playback moves on.
public struct LiquidPhotos: View {
    private let images: [UIImage]
    @Binding private var selection: Int
    @Binding private var isPlaying: Bool
    private let style: LiquidPhotosStyle
    @State private var isMoving = false

    /// - Parameters:
    ///   - images: The photos, in order. The same `UIImage` instances keep
    ///     their prepared state when the array changes.
    ///   - selection: The photo shown; set it to morph to another. Playback
    ///     advances it.
    ///   - isPlaying: Plays through the photos, holding each for
    ///     `style.holdDuration`.
    public init(
        _ images: [UIImage],
        selection: Binding<Int>,
        isPlaying: Binding<Bool> = .constant(false),
        style: LiquidPhotosStyle = LiquidPhotosStyle()
    ) {
        self.images = images
        _selection = selection
        _isPlaying = isPlaying
        self.style = style
    }

    public var body: some View {
        LiquidStage(
            images: images,
            selection: selection,
            isPlaying: isPlaying,
            style: style,
            onSelect: { selection = $0 },
            onPlaybackEnd: { isPlaying = false },
            onMotion: { isMoving = $0 }
        )
        .accessibilityElement()
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(images.isEmpty ? "No photos" : "Photo \(min(selection, images.count - 1) + 1) of \(images.count)")
        .accessibilityValue(isMoving ? "transitioning" : "settled")
        .accessibilityIdentifier("liquidPhotos.stage")
    }
}

private struct LiquidStage: UIViewRepresentable {
    let images: [UIImage]
    let selection: Int
    let isPlaying: Bool
    let style: LiquidPhotosStyle
    let onSelect: (Int) -> Void
    let onPlaybackEnd: () -> Void
    let onMotion: (Bool) -> Void

    func makeUIView(context: Context) -> LiquidStageView {
        LiquidStageView()
    }

    func updateUIView(_ view: LiquidStageView, context: Context) {
        guard let engine = view.engine else { return }
        engine.onSelect = onSelect
        engine.onPlaybackEnd = onPlaybackEnd
        engine.onMotion = onMotion
        engine.style = style
        view.cornerRadius = style.cornerRadius
        engine.setPhotos(images, selection: selection)
        engine.isPlaying = isPlaying && images.count > 1
        view.wake()
    }

    static func dismantleUIView(_ view: LiquidStageView, coordinator: ()) {
        view.isPaused = true
    }
}

/// The Metal view: one full-screen triangle a frame, driven by a display
/// link at up to the screen's full rate (120 Hz on ProMotion) while
/// morphing, and paused when nothing moves.
final class LiquidStageView: MTKView {
    private(set) var engine: LiquidEngine?
    private var pipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private var fallbackTexture: MTLTexture?
    private var displayLink: CADisplayLink?
    private var linkRate = 0
    private var lastTimestamp: CFTimeInterval?
    private var pendingDelta: Double = 0
    var cornerRadius: CGFloat = 0

    init() {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        isOpaque = false
        backgroundColor = .clear
        layer.isOpaque = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        enableSetNeedsDisplay = false
        isPaused = true
        guard let device else { return }
        queue = device.makeCommandQueue()
        engine = LiquidEngine(device: device)
        engine?.onNeedsDisplay = { [weak self] in self?.wake() }
        pipeline = Self.makePipeline(device: device, format: colorPixelFormat)
        fallbackTexture = Self.makeFallbackTexture(device: device)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Resumes drawing; the loop pauses itself again once settled.
    func wake() {
        guard window != nil else { return }
        if displayLink == nil {
            let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        if displayLink?.isPaused == true || linkRate == 0 {
            lastTimestamp = nil
            setRate(60)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            displayLink?.invalidate()
            displayLink = nil
            linkRate = 0
        } else {
            wake()
        }
    }

    fileprivate func tick(_ link: CADisplayLink) {
        // Step by the frames' target times, so motion lands evenly on screen.
        let target = link.targetTimestamp
        pendingDelta = lastTimestamp.map { target - $0 } ?? 0
        lastTimestamp = target
        draw()
    }

    private func setRate(_ fps: Int) {
        guard let link = displayLink else { return }
        if fps == 0 {
            link.isPaused = true
            linkRate = 0
            return
        }
        link.isPaused = false
        guard fps != linkRate else { return }
        linkRate = fps
        let f = Float(fps)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(f, 30), maximum: f, preferred: f)
    }

    override func draw(_ rect: CGRect) {
        guard let engine, let pipeline, let queue, bounds.width > 0, bounds.height > 0 else { return }
        let maxHeight = Double(bounds.height / bounds.width)
        let state = engine.advance(by: pendingDelta, maxHeight: maxHeight)
        pendingDelta = 0
        // Full rate while morphing, a gentle rate for the drift, none at rest.
        setRate(state?.frameRate ?? 0)

        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let state {
            var uniforms = makeUniforms(state, drawableSize: drawableSize)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * uniforms.count, index: 0)
            encoder.setFragmentTexture(state.textureA, index: 0)
            encoder.setFragmentTexture(state.textureB ?? fallbackTexture, index: 1)
            encoder.setFragmentTexture(state.flow?.texture ?? fallbackTexture, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private func makeUniforms(_ s: LiquidDrawState, drawableSize: CGSize) -> [SIMD4<Float>] {
        let unit = Float(drawableSize.width)
        let c = s.camera
        let b = s.frameB ?? s.frameA
        return [
            SIMD4(Float(drawableSize.width), Float(drawableSize.height), unit, Float(c.halfHeight)),
            SIMD4(Float(drawableSize.width) / 2, Float(drawableSize.height) / 2,
                  Float(cornerRadius / max(bounds.width, 1)), Float(c.morph)),
            SIMD4(Float(c.center.x), Float(c.center.y), Float(c.scale), Float(c.blur)),
            SIMD4(Float(s.frameA.anchor.x), Float(s.frameA.anchor.y), Float(s.sizeA), Float(s.frameA.height)),
            SIMD4(Float(b.anchor.x), Float(b.anchor.y), Float(s.sizeB), Float(b.height)),
            SIMD4(s.flow?.origin.x ?? 0, s.flow?.origin.y ?? 0, s.flow?.size.x ?? 1, s.flow?.size.y ?? 1),
            SIMD4(s.flow == nil ? 0 : Float(engine?.style.morph ?? 1), s.flow?.swapped == true ? 1 : 0,
                  s.textureB == nil ? 0 : 1, Float(s.opacity)),
            SIMD4(17.3, 0.4, Float(s.textureA.width), Float(s.textureB?.width ?? 1)),
            SIMD4(Float(s.velocity.x), Float(s.velocity.y), Float(s.velocity.z), 1 / 60),
        ]
    }

    private static func makePipeline(device: MTLDevice, format: MTLPixelFormat) -> MTLRenderPipelineState? {
        guard let library = try? device.makeDefaultLibrary(bundle: .module) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "liquidVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "liquidFragment")
        descriptor.colorAttachments[0].pixelFormat = format
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makeFallbackTexture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        return device.makeTexture(descriptor: descriptor)
    }
}

/// Breaks the display link's strong hold on its target.
@MainActor
private final class DisplayLinkTarget: NSObject {
    weak var view: LiquidStageView?
    init(_ view: LiquidStageView) { self.view = view }
    @objc func tick(_ link: CADisplayLink) {
        guard let view else { return link.invalidate() }
        view.tick(link)
    }
}
