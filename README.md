# LiquidPhotos

Photos that animate into each other. When two photos show the same scene,
they are aligned, and the camera moves from one viewpoint to the other while
every pixel travels to its place in the next photo. A closer shot of the cat
plays like walking up to the cat, and the same group in new poses plays like
the people moving. When two photos have nothing in common, their pixels
still flow into each other in place. One Metal pass draws it, with no
generative model.

![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![iOS 17+](https://img.shields.io/badge/iOS-17%2B-blue) ![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen)

```swift
LiquidPhotos(photos, selection: $index, isPlaying: $playing)
```

That is the whole integration.

## Installation

Add `https://github.com/haplollc/LiquidPhotos` in Xcode, or in Package.swift:

```swift
.package(url: "https://github.com/haplollc/LiquidPhotos", from: "1.0.0")
```

## Quick start

```swift
import LiquidPhotos

struct Slideshow: View {
    let photos: [UIImage]
    @State private var index = 0
    @State private var playing = false

    var body: some View {
        VStack {
            LiquidPhotos(photos, selection: $index, isPlaying: $playing)
            LiquidPhotoStrip(photos, selection: $index)
            Button(playing ? "Pause" : "Play") { playing.toggle() }
        }
    }
}
```

Changing `selection` morphs to that photo. While `isPlaying` is true, the
stage holds each photo and then moves on. When it reaches the end it loops,
or it stops and sets `isPlaying` back to false.

## Style

```swift
LiquidPhotos(photos, selection: $index, isPlaying: $playing, style: LiquidPhotosStyle(
    transitionDuration: 1.5,   // seconds per transition
    holdDuration: 1.8,         // seconds each photo holds while playing
    loops: true,
    morph: 1,                  // how far pixels travel (0 cross-fades in place)
    cornerRadius: 0
))
```

## How it works

- **Alignment.** For each pair, it searches for where one photo sits inside
  the other: a scaled, shifted window, both ways round, coarse to fine. The
  score is colour correlation, and the pair counts as the same scene above
  0.7. A close-up becomes a small window of the wide shot, and a step aside
  becomes a shifted one.
- **Camera.** The frame shows a quad of the first photo's world. A
  transition moves it from the first photo's view to the second's. Position
  is eased with smootherstep and size is interpolated logarithmically, so the
  approach feels steady. The frame reshapes to the new photo along the way.
- **Matches, not swirls.** A dense optical flow only *proposes* where things
  went. Each proposal is kept only if a 7×7 patch looks the same in both
  photos (correlation ≥ 0.8), so a guess that only roughly fits is never
  shown as motion.
- **Solid pieces.** A 24-column grid mesh is fitted to the kept matches. The
  fit is the content-preserving warp of Liu, Gleicher, Jin & Agarwala
  (2009), the method behind After Effects' Warp Stabilizer: every triangle
  resists changing shape, and the fit is reweighted so a few bad matches
  can't bend a region. Matched regions move, scale and turn as solid pieces,
  and the rest follow their neighbours rigidly. The GPU draws the mesh as
  triangles, so the warp is smooth everywhere.
- **Re-tinting.** Each vertex carries the local colour shift between the
  photos as a gain and an offset. Pixels shift colour as they move, so the
  same thing in different light changes its look instead of dissolving.
- **Fallback.** Where the moved, re-tinted pixels still disagree (something
  genuinely appears or leaves), that spot cross-fades slowly instead of
  being pulled around. This is the idea behind After Effects' Timewarp
  "Error Threshold". Both ideas came from studying
  [EffectCraft](https://github.com/storytold/effectcraft)'s clean-room
  reimplementations; no code was copied.
- **Frame rate.** A display link steps the clock by each frame's target
  time, at up to 120 Hz while morphing. On iPhone that needs
  `CADisableMinimumFrameDurationOnPhone` set to true in your Info.plist. At
  rest the view stops drawing entirely. Textures are kept for the six most
  recently used photos, and the neighbours' textures and morphs are prepared
  ahead of time, at low priority.

## Requirements

iOS 17+, Swift 6, a Metal device.

## License

MIT. Made by [Haplo LLC](https://haploapp.com).
