import SwiftUI
import XCTest
import LiquidPhotos

// Every code sample in the README, compiled here so the docs can't drift
// from the API.

private struct QuickStartAlbum: View {
    @State private var photos: [UIImage] = []

    var body: some View {
        LiquidAlbum($photos)
    }
}

private struct Slideshow: View {
    let photos: [UIImage]
    @State private var index = 0
    @State private var playing = false

    var body: some View {
        VStack {
            LiquidPhotos(photos, selection: $index, isPlaying: $playing)
            LiquidPhotoStrip(photos, selection: $index) {
                Button(playing ? "Pause" : "Play") { playing.toggle() }
            }
        }
    }
}

private struct StyledAlbum: View {
    @State private var photos: [UIImage] = []

    var body: some View {
        LiquidAlbum($photos, style: LiquidPhotosStyle(
            transitionDuration: 1.5,   // seconds per transition
            holdDuration: 1.8,         // seconds each photo holds while playing
            loops: true,
            morph: 1,                  // how far pixels travel (0 cross-fades in place)
            cornerRadius: 0
        ), startsPlaying: true)
    }
}

private struct FixedAlbum: View {
    @State private var photos: [UIImage] = []

    var body: some View {
        LiquidAlbum($photos, allowsAdding: false)
    }
}

@MainActor
final class ReadmeExamples: XCTestCase {
    /// The samples build and lay out.
    func testSamplesRender() {
        let photos = [UIImage(systemName: "photo")!, UIImage(systemName: "star")!]
        for view in [AnyView(QuickStartAlbum()), AnyView(Slideshow(photos: photos)), AnyView(StyledAlbum()), AnyView(FixedAlbum())] {
            let host = UIHostingController(rootView: view)
            host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            host.view.layoutIfNeeded()
            XCTAssertNotNil(host.view)
        }
    }
}
