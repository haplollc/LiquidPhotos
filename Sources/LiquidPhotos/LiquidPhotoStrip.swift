//
//  LiquidPhotoStrip.swift
//  LiquidPhotos
//
//  The filmstrip under the stage: a shelf of photos stacked edge-on like CDs,
//  the one on screen turned out to face you. Choosing another flips it out of
//  the stack in 3D while the last one turns back in. Tap one to morph to it,
//  or drag the shelf.
//

import SwiftUI

/// A shelf of thumbnails centred on the selected photo, with an optional
/// trailing view (e.g. an add button) pinned at its right edge.
public struct LiquidPhotoStrip<Trailing: View>: View {
    private let images: [UIImage]
    @Binding private var selection: Int
    private let trailing: Trailing
    private let size: CGFloat
    @State private var drag: CGFloat = 0

    /// - Parameters:
    ///   - size: The side of a stacked thumbnail; the one facing you is a
    ///     quarter larger.
    ///   - trailing: Pinned at the right edge, e.g. an add button.
    public init(
        _ images: [UIImage],
        selection: Binding<Int>,
        size: CGFloat = 44,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.images = images
        _selection = selection
        self.size = size
        self.trailing = trailing()
    }

    /// Follows the recording clock, so a paced take keeps the strip in step.
    private var glide: Animation { .spring(response: 0.5 * LiquidTime.pace, dampingFraction: 0.86) }
    private var facingSize: CGFloat { size * 1.27 }
    /// From the facing card's centre to the first stacked one.
    private var first: CGFloat { facingSize * 0.78 }
    /// Between stacked cards: their spines.
    private var spine: CGFloat { size * 0.22 }
    /// How many stacked cards show on each side; the rest fade into the stack.
    private let shown = 8.0

    public var body: some View {
        GeometryReader { proxy in
            let selected = images.isEmpty ? 0 : min(max(selection, 0), images.count - 1)
            let scrub = -drag / (spine * 2.5)
            ZStack {
                ForEach(images.indices, id: \.self) { index in
                    let d = Double(index - selected) + scrub
                    let pose = Pose(d, first: first, spine: spine, shown: shown)
                    StripThumbnail(image: images[index], isFacing: index == selected, side: facingSize, turn: pose.turn)
                        .scaleEffect(pose.scale)
                        .opacity(pose.opacity)
                        .position(x: proxy.size.width / 2 + pose.x, y: proxy.size.height / 2)
                        .zIndex(-abs(d))
                        .onTapGesture { selection = index }
                        .accessibilityElement()
                        .accessibilityLabel("Photo \(index + 1)")
                        .accessibilityAddTraits(index == selected ? [.isButton, .isSelected] : .isButton)
                        .accessibilityIdentifier("liquidPhotos.thumb.\(index)")
                }
            }
            .animation(glide, value: selected)
            .animation(glide, value: images.count)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { drag = $0.translation.width }
                    .onEnded { value in
                        let moved = Int((-value.predictedEndTranslation.width / (spine * 2.5)).rounded())
                        withAnimation(glide) {
                            drag = 0
                            if !images.isEmpty {
                                selection = min(max(selected + moved, 0), images.count - 1)
                            }
                        }
                    }
            )
        }
        .frame(height: facingSize + 16)
        .overlay(alignment: .trailing) {
            trailing.padding(.trailing, 16)
        }
    }
}

/// Where a card sits for its distance `d` from the facing one: the nearest
/// turn out to face you, the rest stand edge-on, turned toward the middle.
private struct Pose {
    let x: CGFloat
    let turn: Double
    let scale: CGFloat
    let opacity: Double

    init(_ d: Double, first: CGFloat, spine: CGFloat, shown: Double) {
        let a = min(abs(d), 1)
        let side: Double = d < 0 ? -1 : 1
        let stacked = min(max(abs(d) - 1, 0), shown)
        x = CGFloat(side) * (first * CGFloat(a) + spine * CGFloat(stacked))
        turn = side * 70 * a
        scale = 1 - 0.12 * CGFloat(a)
        opacity = abs(d) > shown + 1 ? 0 : 1
    }
}

private struct StripThumbnail: View {
    let image: UIImage
    let isFacing: Bool
    let side: CGFloat
    let turn: Double
    @State private var thumbnail: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
            .fill(Color.gray.opacity(0.18))
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
            // Turned away, a card catches less light.
            .brightness(-0.14 * min(abs(turn) / 70, 1))
            .rotation3DEffect(.degrees(-turn), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
            .shadow(color: .black.opacity(isFacing ? 0.2 : 0.06), radius: isFacing ? 8 : 2, y: isFacing ? 4 : 1)
            .task(id: ObjectIdentifier(image)) {
                thumbnail = await ThumbnailCache.shared.thumbnail(for: image)
            }
    }
}

@MainActor
private final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [ObjectIdentifier: UIImage] = [:]

    func thumbnail(for image: UIImage) async -> UIImage? {
        let id = ObjectIdentifier(image)
        if let hit = cache[id] { return hit }
        let side: CGFloat = 180
        let scale = side / max(1, min(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let made = await image.byPreparingThumbnail(ofSize: size)
        if cache.count > 200 { cache.removeAll() }
        cache[id] = made
        return made
    }
}
