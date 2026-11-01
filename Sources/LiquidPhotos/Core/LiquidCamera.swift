//
//  LiquidCamera.swift
//  LiquidPhotos
//
//  Where the camera looks during a transition.
//
//  Every length here is in stage widths: a photo at rest is one unit wide
//  and `1 / aspect` tall, centred on the origin, y pointing down. Each photo
//  has an anchor, the subject the eye goes to. Through a transition both
//  photos are drawn so that their anchors land on the same spot at the same
//  size, gliding from where the first photo's subject sits to where the
//  second one's will. The cat becomes the bullring at the same place on the
//  glass, and the frame reshapes around it.
//
//  In "anchor space" (η, the stage position relative to that shared spot,
//  divided by the shared size) photo X is simply `anchor_X + η · size_X`,
//  the same at every instant. That is what lets one flow field, computed
//  once in η, morph the pair for the whole transition.
//

import CoreGraphics
import Foundation
import simd

/// A photo's shape and subject, in stage widths.
struct LiquidFrame: Equatable, Sendable {
    /// The photo's height at one unit wide, `1 / aspect`.
    var height: Double
    /// The subject's centre, from the photo's centre (y down).
    var anchor: SIMD2<Double>
    /// The subject's size (the geometric mean of its width and height).
    var anchorSize: Double

    /// A photo with its subject given as a rectangle in unit coordinates
    /// (0...1 across the photo, origin top left).
    init(aspect: Double, subject: CGRect) {
        let h = 1 / max(aspect, 0.05)
        height = h
        let cx = Double(subject.midX) - 0.5
        let cy = (Double(subject.midY) - 0.5) * h
        // Keep the subject well inside so the camera never has to chase an edge.
        anchor = SIMD2(
            min(max(cx, -0.3), 0.3),
            min(max(cy, -0.3 * h), 0.3 * h)
        )
        let size = (Double(subject.width) * Double(subject.height) * h).squareRoot()
        anchorSize = min(max(size, 0.2), 0.85)
    }

    init(height: Double, anchor: SIMD2<Double>, anchorSize: Double) {
        self.height = height
        self.anchor = anchor
        self.anchorSize = anchorSize
    }

    /// The photo's height on a stage `maxHeight` tall at most.
    func visibleHeight(maxHeight: Double) -> Double { min(height, maxHeight) }
}

/// What the renderer needs for one frame.
struct LiquidCamera: Equatable, Sendable {
    /// Half the photo frame's height (its width is always one).
    var halfHeight: Double
    /// The shared anchor's position on the stage.
    var center: SIMD2<Double>
    /// Stage units per anchor-space unit: `size · zoom`.
    var scale: Double
    /// 0 shows the first photo, 1 the second; the flow and dissolve follow it.
    var morph: Double
    /// Defocus radius in stage widths.
    var blur: Double

    /// Where stage point `p` reads photo `frame` (in that photo's own
    /// centred units), ignoring the flow.
    func source(of p: SIMD2<Double>, anchor: SIMD2<Double>, size: Double) -> SIMD2<Double> {
        anchor + (p - center) / scale * size
    }
}

/// Tuning for the camera's motion through a transition.
struct LiquidMotion: Equatable, Sendable {
    /// How much further the camera pushes in at the middle of a transition.
    var push: Double = 0.28
    /// Peak defocus, in stage widths.
    var blur: Double = 0.014
    /// The furthest one anchor may be scaled against the other.
    var maxSizeRatio: Double = 2.2
    /// The most the camera may zoom in to keep both photos covering the frame.
    var maxCoverZoom: Double = 2.4

    static let reduced = LiquidMotion(push: 0, blur: 0, maxSizeRatio: 1, maxCoverZoom: 1)
}

/// The shared geometry of a pair of photos, the same in either direction.
struct LiquidPairGeometry: Equatable, Sendable {
    var a: LiquidFrame
    var b: LiquidFrame
    /// The anchor sizes the pair aligns with: the photos' own, pulled toward
    /// each other so neither has to zoom absurdly far to meet the other.
    var sizeA: Double
    var sizeB: Double

    init(_ a: LiquidFrame, _ b: LiquidFrame, maxSizeRatio: Double = 2.2) {
        self.a = a
        self.b = b
        let mean = (a.anchorSize * b.anchorSize).squareRoot()
        let ratio = min(max(b.anchorSize / a.anchorSize, 1 / maxSizeRatio), maxSizeRatio)
        sizeA = mean / ratio.squareRoot()
        sizeB = mean * ratio.squareRoot()
    }

    /// The same pair seen from the other side.
    var reversed: LiquidPairGeometry {
        var r = self
        swap(&r.a, &r.b)
        swap(&r.sizeA, &r.sizeB)
        return r
    }

    /// The part of anchor space either photo shows at rest, padded a little:
    /// where the flow between them is needed.
    func flowWindow(maxHeight: Double) -> (origin: SIMD2<Double>, size: SIMD2<Double>) {
        func extent(_ f: LiquidFrame, _ s: Double) -> (SIMD2<Double>, SIMD2<Double>) {
            let half = SIMD2(0.5, f.visibleHeight(maxHeight: maxHeight) / 2)
            return ((-half - f.anchor) / s, (half - f.anchor) / s)
        }
        let (loA, hiA) = extent(a, sizeA)
        let (loB, hiB) = extent(b, sizeB)
        let lo = simd_min(loA, loB), hi = simd_max(hiA, hiB)
        let pad = (hi - lo) * 0.06
        return (lo - pad, hi - lo + 2 * pad)
    }

    /// The camera `t` of the way through, 0...1 linear in time.
    ///
    /// - Parameters:
    ///   - startZoom: How far the first photo had already drifted in.
    ///   - maxHeight: The tallest frame the stage can show, in widths.
    func camera(at t: Double, startZoom: Double, maxHeight: Double, motion: LiquidMotion) -> LiquidCamera {
        let t = min(max(t, 0), 1)
        let glide = LiquidEase.smoother(t)
        let center = a.anchor + (b.anchor - a.anchor) * glide
        let size = sizeA * pow(sizeB / sizeA, glide)
        let halfHeight = 0.5 * (a.visibleHeight(maxHeight: maxHeight)
            + (b.visibleHeight(maxHeight: maxHeight) - a.visibleHeight(maxHeight: maxHeight)) * LiquidEase.smoother(t))
        let bump = LiquidEase.bump(t)
        let morph = LiquidEase.morph(t)

        var zoom = (startZoom + (1 - startZoom) * glide) * (1 + motion.push * bump)

        // Zoom in further while it would otherwise show past a photo's edge,
        // but only as far as that photo is still visible.
        let needA = coverZoom(a, anchorSize: sizeA, center: center, scale: size * zoom, halfHeight: halfHeight)
        let needB = coverZoom(b, anchorSize: sizeB, center: center, scale: size * zoom, halfHeight: halfHeight)
        let showsA = 1 - LiquidEase.step(0.55, 0.97, morph)
        let showsB = LiquidEase.step(0.03, 0.45, morph)
        let cover = max(1, 1 + (needA - 1) * showsA, 1 + (needB - 1) * showsB)
        zoom *= min(cover, motion.maxCoverZoom)

        return LiquidCamera(
            halfHeight: halfHeight,
            center: center,
            scale: size * zoom,
            morph: morph,
            blur: motion.blur * pow(bump, 0.8)
        )
    }

    /// How much more the camera must zoom (about its centre) for photo `f`
    /// to cover the whole frame.
    private func coverZoom(_ f: LiquidFrame, anchorSize: Double, center: SIMD2<Double>, scale: Double, halfHeight: Double) -> Double {
        let k = anchorSize / scale
        let roomX = (lo: 0.5 + f.anchor.x, hi: 0.5 - f.anchor.x)
        let roomY = (lo: f.height / 2 + f.anchor.y, hi: f.height / 2 - f.anchor.y)
        let reachX = (lo: 0.5 + center.x, hi: 0.5 - center.x)
        let reachY = (lo: halfHeight + center.y, hi: halfHeight - center.y)
        return max(
            k * reachX.lo / max(roomX.lo, 1e-3),
            k * reachX.hi / max(roomX.hi, 1e-3),
            k * reachY.lo / max(roomY.lo, 1e-3),
            k * reachY.hi / max(roomY.hi, 1e-3)
        )
    }
}

extension LiquidFrame {
    /// The camera resting on this photo, drifted in by `zoom`.
    func restingCamera(zoom: Double, maxHeight: Double) -> LiquidCamera {
        LiquidCamera(
            halfHeight: visibleHeight(maxHeight: maxHeight) / 2,
            center: anchor,
            scale: anchorSize * zoom,
            morph: 0,
            blur: 0
        )
    }
}

/// The curves a transition is built from.
enum LiquidEase {
    static func step(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Ken Perlin's smootherstep: zero velocity and acceleration at both ends.
    static func smoother(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// 0 at both ends, 1 in the middle, flat at the ends.
    static func bump(_ t: Double) -> Double {
        let s = sin(Double.pi * min(max(t, 0), 1))
        return s * s
    }

    /// The dissolve's progress: held at the ends while the camera moves,
    /// so each photo starts and lands without a trace of the other.
    static func morph(_ t: Double) -> Double {
        smoother(min(max((t - 0.1) / 0.8, 0), 1))
    }

    /// How far the camera has drifted in after `seconds` resting on a photo.
    static func drift(after seconds: Double, amount: Double) -> Double {
        1 + amount * (1 - exp(-max(seconds, 0) / 7))
    }
}
