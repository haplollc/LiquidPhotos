//
//  LiquidAlbum.swift
//  LiquidPhotos
//
//  The whole thing in one view: the stage, the shelf of photos under it, a
//  play button on its left and a + on its right that adds photos from the
//  library.
//
//      LiquidAlbum($photos)
//

import PhotosUI
import SwiftUI

/// A ready-made liquid photo album: the `LiquidPhotos` stage, a
/// `LiquidPhotoStrip` shelf under it, play/pause, and a + that opens the
/// photo picker and appends what's chosen to `photos`.
public struct LiquidAlbum: View {
    @Binding private var photos: [UIImage]
    private let style: LiquidPhotosStyle
    private let allowsAdding: Bool
    @State private var selection = 0
    @State private var isPlaying = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var isImporting = false

    /// - Parameters:
    ///   - photos: The album's photos. Photos added with the + are appended.
    ///   - style: How the stage moves.
    ///   - allowsAdding: Shows the + button.
    ///   - startsPlaying: Plays as soon as there are two photos.
    public init(
        _ photos: Binding<[UIImage]>,
        style: LiquidPhotosStyle = LiquidPhotosStyle(),
        allowsAdding: Bool = true,
        startsPlaying: Bool = false
    ) {
        _photos = photos
        self.style = style
        self.allowsAdding = allowsAdding
        _isPlaying = State(initialValue: startsPlaying)
    }

    public var body: some View {
        VStack(spacing: 0) {
            LiquidPhotos(photos, selection: $selection, isPlaying: $isPlaying, style: style)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            LiquidPhotoStrip(photos, selection: $selection) {
                if allowsAdding { addButton }
            }
            .overlay(alignment: .leading) { playButton.padding(.leading, 16) }
            .padding(.vertical, 14)
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            Task { await add(items) }
        }
    }

    private var playButton: some View {
        Button {
            isPlaying.toggle()
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 46, height: 46)
                .modifier(GlassCircle())
        }
        .buttonStyle(.plain)
        .disabled(photos.count < 2)
        .opacity(photos.count < 2 ? 0.4 : 1)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .accessibilityIdentifier("liquidAlbum.play")
    }

    private var addButton: some View {
        PhotosPicker(selection: $picked, maxSelectionCount: nil, selectionBehavior: .ordered, matching: .images) {
            Image(systemName: isImporting ? "hourglass" : "plus")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 46, height: 46)
                .modifier(GlassCircle())
        }
        .buttonStyle(.plain)
        .disabled(isImporting)
        .accessibilityLabel("Add Photos")
        .accessibilityIdentifier("liquidAlbum.add")
    }

    private func add(_ items: [PhotosPickerItem]) async {
        isImporting = true
        var loaded: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                loaded.append(image)
            }
        }
        picked = []
        isImporting = false
        guard !loaded.isEmpty else { return }
        let wasEmpty = photos.isEmpty
        photos += loaded
        if wasEmpty { selection = 0 }
    }
}

/// Liquid Glass on iOS 26 and later, a material circle before it.
private struct GlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.foregroundStyle(.primary).glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.foregroundStyle(.primary).background(.ultraThinMaterial, in: Circle())
        }
    }
}
