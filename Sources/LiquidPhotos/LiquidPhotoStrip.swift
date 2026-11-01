//
//  LiquidPhotoStrip.swift
//  LiquidPhotos
//
//  The filmstrip under the stage: small rounded thumbnails, the selected one
//  larger and centred. Tap one to morph to it, or swipe the strip.
//

import SwiftUI

/// A thumbnail strip centred on the selected photo.
public struct LiquidPhotoStrip<Trailing: View>: View {
    private let images: [UIImage]
    @Binding private var selection: Int
    private let trailing: Trailing
    private let size: CGFloat
    @State private var drag: CGFloat = 0

    /// - Parameters:
    ///   - size: The side of an unselected thumbnail; the selected one is a
    ///     quarter larger.
    ///   - trailing: Shown after the last thumbnail, e.g. an add button.
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

    private var spacing: CGFloat { size * 0.12 }
    /// Follows the recording clock, so a paced take keeps the strip in step.
    private var glide: Animation { .spring(response: 0.42 * LiquidTime.pace, dampingFraction: 0.86) }
    private var selectedSize: CGFloat { size * 1.27 }

    public var body: some View {
        GeometryReader { proxy in
            let step = size + spacing
            let selected = images.isEmpty ? 0 : min(max(selection, 0), images.count - 1)
            let centre = images.isEmpty ? -spacing : CGFloat(selected) * step + selectedSize / 2
            HStack(spacing: spacing) {
                ForEach(images.indices, id: \.self) { index in
                    StripThumbnail(image: images[index], isSelected: index == selected, side: index == selected ? selectedSize : size)
                        .onTapGesture { selection = index }
                        .accessibilityElement()
                        .accessibilityLabel("Photo \(index + 1)")
                        .accessibilityAddTraits(index == selected ? [.isButton, .isSelected] : .isButton)
                        .accessibilityIdentifier("liquidPhotos.thumb.\(index)")
                }
                trailing
            }
            .fixedSize()
            // A layout shift, not an offset, so hit testing and accessibility
            // frames follow the thumbnails.
            .alignmentGuide(.leading) { _ in centre + -proxy.size.width / 2 - drag }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .animation(glide, value: selected)
            .animation(glide, value: images.count)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { drag = $0.translation.width }
                    .onEnded { value in
                        let moved = Int((-value.predictedEndTranslation.width / step).rounded())
                        withAnimation(glide) {
                            drag = 0
                            if !images.isEmpty {
                                selection = min(max(selected + moved, 0), images.count - 1)
                            }
                        }
                    }
            )
        }
        .frame(height: selectedSize + 8)
    }
}

private struct StripThumbnail: View {
    let image: UIImage
    let isSelected: Bool
    let side: CGFloat
    @State private var thumbnail: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.2, style: .continuous)
            .fill(Color.gray.opacity(0.18))
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.2, style: .continuous))
            .shadow(color: .black.opacity(isSelected ? 0.18 : 0), radius: 6, y: 3)
            .opacity(isSelected ? 1 : 0.72)
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
