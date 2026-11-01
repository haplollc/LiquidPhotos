# LiquidPhotos

Photos that melt into each other. Each transition glides the camera from one
photo's subject to the next one's, reshapes the frame to the new photo, and
flows the pictures into each other through a soft defocus. It runs in one
Metal pass, with no generative model.

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
    transitionDuration: 1.6,   // seconds per transition
    holdDuration: 1.8,         // seconds each photo holds while playing
    loops: true,
    morph: 1,                  // how far the pictures flow (0: dissolve in place)
    defocus: 1,                // how soft the middle gets (0: stays sharp)
    push: 1,                   // how far the camera pushes in
    drift: true,               // a resting photo slowly drifts toward its subject
    cornerRadius: 0
))
```

## How it works

- **Subjects.** Vision's attention saliency finds each photo's subject. If
  Vision can't run, a centre-weighted colour-contrast guess stands in.
- **Camera.** Through a transition, both photos are drawn so that their
  subjects land on the same spot at the same size. That spot glides from
  where the first photo's subject sits to where the second one's will. The
  camera pushes in through the middle, and zooms in further only as far as
  it must to keep a visible photo covering the frame.
- **Flow.** Horn–Schunck optical flow runs between the two photos in that
  shared, subject-aligned space. It is coarse to fine, on a grid of about 64
  cells, in both directions, off the main thread. Each photo is warped along
  the flow toward the other while they dissolve in soft noise patches. The
  flow is kept very smooth, so broad regions (sky, a subject, the ground)
  slide into each other instead of texture tearing.
- **Defocus.** A 12-tap disc on the mip level its radius needs peaks
  mid-transition.
- **Motion blur.** The same 12 taps are sheared along the way the camera
  moves the picture: its glide plus its zoom, over a 1/60 s shutter. That is
  most of what makes a rendered move read as smooth as filmed video.
- **Frame rate.** A display link steps the clock by each frame's target
  time, at up to 120 Hz while morphing. On iPhone that needs
  `CADisableMinimumFrameDurationOnPhone` set to true in your Info.plist. It
  drops to 30 fps while a resting photo drifts and stops once it settles.
  At rest a pixel is one texture read. Textures are kept for the six most
  recently used photos, and the neighbours' textures and flows are prepared
  ahead of time.

## Requirements

iOS 17+, Swift 6, a Metal device.

## License

MIT. Made by [Haplo LLC](https://haploapp.com).
