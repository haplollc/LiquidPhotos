//
//  LiquidEngine.swift
//  LiquidPhotos
//
//  The stage's state machine: which photo is showing, the transition in
//  flight, playback, and the work done ahead of time (textures, subjects,
//  flows) so a transition never waits when it can avoid it.
//

import Metal
import UIKit

/// The recording clock. Everything on the stage runs `pace` times slower
/// than real time, so a busy machine can record smooth frames that are sped
/// back up afterwards.
@_spi(Recording)
@MainActor
public enum LiquidTime {
    public static var pace: Double = 1
}

/// What the renderer draws this frame.
struct LiquidDrawState {
    var camera: LiquidCamera
    var textureA: MTLTexture
    var frameA: LiquidFrame
    var sizeA: Double
    var textureB: MTLTexture?
    var frameB: LiquidFrame?
    var sizeB: Double
    var flow: (texture: MTLTexture, origin: SIMD2<Float>, size: SIMD2<Float>, swapped: Bool)?
    var opacity: Double
    /// How the camera is moving, for motion blur: the shared anchor's
    /// velocity (xy, stage widths a second) and the zoom's rate (z, log
    /// scale a second).
    var velocity: SIMD3<Double> = .zero
    /// Frames a second this needs: full rate while morphing, a gentle rate
    /// for the drift, a trickle while only waiting, none when settled.
    var frameRate: Int
}

@MainActor
final class LiquidEngine {
    var style = LiquidPhotosStyle()
    var reduceMotion = UIAccessibility.isReduceMotionEnabled

    /// The selection changed by itself (playback moved on).
    var onSelect: ((Int) -> Void)?
    /// Playback reached the last photo and does not loop.
    var onPlaybackEnd: (() -> Void)?
    /// A transition started (true) or landed (false).
    var onMotion: ((Bool) -> Void)?
    /// Called whenever something new is ready to draw.
    var onNeedsDisplay: (() -> Void)?

    let device: MTLDevice
    private let maxPixelSize: Int

    private var photos: [(id: ObjectIdentifier, image: UIImage)] = []
    private var infos: [ObjectIdentifier: LiquidPhotoInfo] = [:]
    private var textures: [ObjectIdentifier: MTLTexture] = [:]
    private var textureUse: [ObjectIdentifier: Int] = [:]
    private var useCounter = 0
    private var loading: Set<ObjectIdentifier> = []
    private var flows: [PairKey: (flow: LiquidPairFlow, texture: MTLTexture)] = [:]
    private var flowing: Set<PairKey> = []

    private struct PairKey: Hashable {
        let low: ObjectIdentifier, high: ObjectIdentifier
        init(_ a: ObjectIdentifier, _ b: ObjectIdentifier) {
            low = min(a, b)
            high = max(a, b)
        }
    }

    private struct Transition {
        let from: ObjectIdentifier
        let to: ObjectIdentifier
        let geometry: LiquidPairGeometry
        let startZoom: Double
        let flowKey: PairKey?
        let swapped: Bool
        var progress: Double = 0
        var speed: Double = 1
    }

    private var shown: ObjectIdentifier?
    private var requested: ObjectIdentifier?
    private var transition: Transition?
    private var appear: Double = 1
    private var restTime: Double = 0
    private var waitingForFlow: Double = 0
    private var playKick = false
    private var isMoving = false

    /// Reports motion from the moment a new photo is asked for until it lands.
    private func reportMotion(_ moving: Bool) {
        guard moving != isMoving else { return }
        isMoving = moving
        onMotion?(moving)
    }

    var isPlaying = false {
        didSet {
            if isPlaying, !oldValue { playKick = true }
            onNeedsDisplay?()
        }
    }

    init(device: MTLDevice, maxPixelSize: Int = 1800) {
        self.device = device
        self.maxPixelSize = maxPixelSize
    }

    // MARK: Inputs

    func setPhotos(_ images: [UIImage], selection: Int) {
        let next = images.map { (id: ObjectIdentifier($0), image: $0) }
        let changed = next.map(\.id) != photos.map(\.id)
        photos = next
        if changed {
            let alive = Set(next.map(\.id))
            infos = infos.filter { alive.contains($0.key) }
            textures = textures.filter { alive.contains($0.key) }
            flows = flows.filter { alive.contains($0.key.low) && alive.contains($0.key.high) }
            if let t = transition, !alive.contains(t.from) || !alive.contains(t.to) { transition = nil }
            if let s = shown, !alive.contains(s) { shown = nil }
        }
        select(selection)
    }

    func select(_ index: Int) {
        guard photos.indices.contains(index) else {
            requested = nil
            return
        }
        let id = photos[index].id
        guard id != requested else { return }
        requested = id
        if id != shown { reportMotion(true) }
        // A new target mid-transition: hurry the current one along.
        if transition != nil { transition?.speed = 2.6 }
        onNeedsDisplay?()
    }

    var currentIndex: Int? {
        guard let shown else { return nil }
        return photos.firstIndex { $0.id == shown }
    }

    // MARK: Frame

    func advance(by realSeconds: Double, maxHeight: Double) -> LiquidDrawState? {
        let dt = min(realSeconds, 0.1) / LiquidTime.pace
        guard !photos.isEmpty else { return nil }

        if shown == nil, let target = requested ?? photos.first?.id {
            if ensureReady(target) {
                shown = target
                if target == requested { reportMotion(false) }
                appear = 0
                restTime = 0
                prefetchNeighbours(of: target)
            }
        }
        guard let shown, let infoA = infos[shown], let textureA = textures[shown] else { return nil }

        appear = min(1, appear + dt / 0.35)
        if var t = transition {
            t.progress += dt * t.speed / max(style.transitionDuration, 0.05)
            if t.progress >= 1 {
                transition = nil
                self.shown = t.to
                restTime = 0
                if requested == t.to || requested == nil { reportMotion(false) }
                prefetchNeighbours(of: t.to)
                return advance(by: 0, maxHeight: maxHeight)
            }
            transition = t
        } else {
            restTime += dt
            advancePlayback()
            if let target = requested, target != shown, startTransition(from: shown, to: target, dt: dt) {
                return advance(by: 0, maxHeight: maxHeight)
            }
        }

        let motion = reduceMotion ? LiquidMotion.reduced : LiquidMotion(
            push: 0.28 * style.push,
            blur: 0.014 * style.defocus
        )
        let driftAmount = style.drift && !reduceMotion ? 0.05 : 0

        if let t = transition, let textureB = textures[t.to] {
            let camera = t.geometry.camera(at: t.progress, startZoom: t.startZoom, maxHeight: maxHeight, motion: motion)
            let step = 0.004
            let ahead = t.geometry.camera(at: min(t.progress + step, 1), startZoom: t.startZoom, maxHeight: maxHeight, motion: motion)
            let behind = t.geometry.camera(at: max(t.progress - step, 0), startZoom: t.startZoom, maxHeight: maxHeight, motion: motion)
            let perSecond = t.speed / max(style.transitionDuration, 0.05) / (min(t.progress + step, 1) - max(t.progress - step, 0))
            let velocity = SIMD3(
                (ahead.center.x - behind.center.x) * perSecond,
                (ahead.center.y - behind.center.y) * perSecond,
                log(ahead.scale / behind.scale) * perSecond
            )
            var flow: LiquidDrawState.Flow?
            if let key = t.flowKey, let f = flows[key], style.morph > 0, !reduceMotion {
                flow = (f.texture, f.flow.origin, f.flow.size, t.swapped)
            }
            touch(t.from)
            touch(t.to)
            return LiquidDrawState(
                camera: camera,
                textureA: textures[t.from] ?? textureA,
                frameA: t.geometry.a, sizeA: t.geometry.sizeA,
                textureB: textureB,
                frameB: t.geometry.b, sizeB: t.geometry.sizeB,
                flow: flow,
                opacity: appear,
                velocity: reduceMotion ? .zero : velocity,
                frameRate: 120
            )
        }

        let frame = infoA.frame
        let zoom = LiquidEase.drift(after: restTime, amount: driftAmount)
        touch(shown)
        return LiquidDrawState(
            camera: frame.restingCamera(zoom: zoom, maxHeight: maxHeight),
            textureA: textureA, frameA: frame, sizeA: frame.anchorSize,
            textureB: nil, frameB: nil, sizeB: 1,
            flow: nil,
            opacity: appear,
            frameRate: appear < 1 ? 60
                : driftAmount > 0 && restTime < 25 ? 30
                : isPlaying || (requested != nil && requested != shown) ? 10
                : 0
        )
    }

    private func advancePlayback() {
        guard isPlaying, photos.count > 1, let shown, requested == shown,
              let index = photos.firstIndex(where: { $0.id == shown }) else { return }
        let due = playKick ? 0.15 : style.holdDuration
        guard restTime >= due else { return }
        if index == photos.count - 1, !style.loops {
            isPlaying = false
            onPlaybackEnd?()
            return
        }
        playKick = false
        let next = (index + 1) % photos.count
        requested = photos[next].id
        reportMotion(true)
        onSelect?(next)
    }

    /// Starts the transition if both photos (and ideally their flow) are ready.
    private func startTransition(from a: ObjectIdentifier, to b: ObjectIdentifier, dt: Double) -> Bool {
        guard ensureReady(a), ensureReady(b), let infoA = infos[a], let infoB = infos[b] else { return false }
        let key = PairKey(a, b)
        let flowReady = flows[key] != nil || reduceMotion || style.morph <= 0
        if !flowReady {
            ensureFlow(key)
            waitingForFlow += dt * LiquidTime.pace
            // Never hold the user up for long; go without the flow instead.
            if waitingForFlow < 1.2 { return false }
        }
        waitingForFlow = 0
        let swapped = a != key.low
        let lowInfo = swapped ? infoB : infoA, highInfo = swapped ? infoA : infoB
        let canonical = LiquidPairGeometry(lowInfo.frame, highInfo.frame)
        let driftAmount = style.drift && !reduceMotion ? 0.05 : 0
        transition = Transition(
            from: a, to: b,
            geometry: swapped ? canonical.reversed : canonical,
            startZoom: LiquidEase.drift(after: restTime, amount: driftAmount),
            flowKey: flows[key] != nil ? key : nil,
            swapped: swapped
        )
        reportMotion(true)
        return true
    }

    // MARK: Preparation

    /// True when the photo's subject and texture are ready; otherwise starts
    /// preparing it.
    @discardableResult
    private func ensureReady(_ id: ObjectIdentifier, urgent: Bool = true) -> Bool {
        if infos[id] != nil, textures[id] != nil { return true }
        guard !loading.contains(id), let image = photos.first(where: { $0.id == id })?.image else { return false }
        loading.insert(id)
        let needsInfo = infos[id] == nil
        let box = UncheckedSendable(value: (image, device))
        let maxPixelSize = maxPixelSize
        Task.detached(priority: urgent ? .userInitiated : .utility) {
            let (image, device) = box.value
            guard let upright = LiquidPreparation.uprightImage(image, maxPixelSize: maxPixelSize) else { return }
            let info = needsInfo ? LiquidPreparation.info(for: upright) : nil
            let texture = try? LiquidPreparation.texture(from: upright, device: device)
            let result = UncheckedSendable(value: (info, texture))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loading.remove(id)
                guard self.photos.contains(where: { $0.id == id }) else { return }
                if let info = result.value.0 { self.infos[id] = info }
                if let texture = result.value.1 {
                    self.textures[id] = texture
                    self.touch(id)
                    self.evictTextures()
                }
                // A neighbour's subject is known now, so its flow can start,
                // while resting rather than mid-transition.
                if self.transition == nil, let shown = self.shown, shown != id {
                    self.prefetchNeighbours(of: shown)
                }
                self.onNeedsDisplay?()
            }
        }
        return false
    }

    private func ensureFlow(_ key: PairKey, urgent: Bool = true) {
        guard flows[key] == nil, !flowing.contains(key), let a = infos[key.low], let b = infos[key.high] else { return }
        flowing.insert(key)
        let device = UncheckedSendable(value: device)
        Task.detached(priority: urgent ? .userInitiated : .utility) {
            let geometry = LiquidPairGeometry(a.frame, b.frame)
            let flow = LiquidPreparation.pairFlow(a, b, geometry: geometry)
            let texture = UncheckedSendable(value: flow.texture(device: device.value))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.flowing.remove(key)
                if let t = texture.value { self.flows[key] = (flow, t) }
                self.onNeedsDisplay?()
            }
        }
    }

    /// Gets the photos either side ready, and their flows with this one.
    private func prefetchNeighbours(of id: ObjectIdentifier) {
        guard let index = photos.firstIndex(where: { $0.id == id }), photos.count > 1 else { return }
        let next = photos[(index + 1) % photos.count].id
        let previous = photos[(index - 1 + photos.count) % photos.count].id
        // Low priority, so preparing what comes next never steals frames
        // from what is on screen.
        for other in [next, previous] where other != id {
            ensureReady(other, urgent: false)
            ensureFlow(PairKey(id, other), urgent: false)
        }
    }

    private func touch(_ id: ObjectIdentifier) {
        useCounter += 1
        textureUse[id] = useCounter
    }

    /// Keeps the GPU copies of the most recently used few photos only.
    private func evictTextures(keeping limit: Int = 6) {
        guard textures.count > limit else { return }
        let protected = Set([shown, requested, transition?.from, transition?.to].compactMap { $0 })
        let victims = textures.keys
            .filter { !protected.contains($0) }
            .sorted { (textureUse[$0] ?? 0) < (textureUse[$1] ?? 0) }
        for id in victims.prefix(textures.count - limit) {
            textures[id] = nil
        }
    }
}

extension LiquidDrawState {
    typealias Flow = (texture: MTLTexture, origin: SIMD2<Float>, size: SIMD2<Float>, swapped: Bool)
}
