//
//  LiquidMorph.swift
//  LiquidPhotos
//
//  How one photo becomes the next, as geometry.
//
//  Everything happens in the first photo's "world": its own coordinates,
//  one unit wide and `heightA` tall (y down). The second photo is placed in
//  that world where it really is: a close-up of the cat sits as a small
//  quad around the cat, a step to the left as a quad shifted right. When
//  the two photos have nothing in common, the second is simply centred.
//
//  A transition moves the camera (the quad the frame shows) from the first
//  photo's view to the second's, with position and rotation eased and size
//  interpolated logarithmically, so it plays like walking closer rather
//  than a zoom effect. Inside that camera, a dense flow moves each pixel from
//  where it is in one photo to where it is in the other.
//

import Foundation
import simd

/// What the renderer needs for one frame of a morph, or of a resting photo.
struct LiquidMorphFrame: Equatable, Sendable {
    /// Half the photo frame's height, in stage widths.
    var halfHeight: Double
    /// Frame unit square (u right, v down) → world, projective.
    var view: simd_double3x3
    /// How far the pixels have travelled along the flow, 0...1.
    var motion: Double
    /// How much of the second photo shows, 0...1.
    var blend: Double
    /// The same, for regions that match: they look alike once moved and
    /// re-tinted, so they can hand over quickly in the middle.
    var quickBlend: Double = 0
}

/// The fixed relationship between two photos, worked out once per pair.
struct LiquidMorph: Sendable {
    /// The first photo's height in widths (the world is 1 × heightA).
    let heightA: Double
    /// The second photo's height in widths.
    let heightB: Double
    /// World → the second photo's own coordinates (1 × heightB), projective.
    let toB: simd_double3x3
    /// The photos show the same scene and were aligned to each other.
    let related: Bool

    /// The second photo centred on the first, both one unit wide: the
    /// placement for photos with nothing in common.
    static func centered(heightA: Double, heightB: Double) -> simd_double3x3 {
        // y_B = y_A - (heightA - heightB) / 2
        simd_double3x3(rows: [
            SIMD3(1, 0, 0),
            SIMD3(0, 1, -(heightA - heightB) / 2),
            SIMD3(0, 0, 1),
        ])
    }

    /// The part of a photo `height` tall that a stage `maxHeight` tall shows:
    /// all of it, or its middle band.
    static func band(height: Double, maxHeight: Double) -> [SIMD2<Double>] {
        let visible = min(height, maxHeight)
        let top = (height - visible) / 2
        return [SIMD2(0, top), SIMD2(1, top), SIMD2(1, top + visible), SIMD2(0, top + visible)]
    }

    /// The first photo's view, in the world.
    func viewA(maxHeight: Double) -> [SIMD2<Double>] {
        Self.band(height: heightA, maxHeight: maxHeight)
    }

    /// The second photo's view, in the world.
    func viewB(maxHeight: Double) -> [SIMD2<Double>] {
        let fromB = toB.inverse
        return Self.band(height: heightB, maxHeight: maxHeight).map { project(fromB, $0) }
    }

    /// The frame `t` of the way from the first photo to the second, 0...1
    /// linear in time. Exactly the first photo at 0 and the second at 1.
    func frame(at t: Double, maxHeight: Double) -> LiquidMorphFrame {
        let t = min(max(t, 0), 1)
        let e = LiquidEase.smoother(t)
        let visibleA = min(heightA, maxHeight), visibleB = min(heightB, maxHeight)
        let visible = visibleA + (visibleB - visibleA) * e
        let quad = LiquidView.interpolate(
            viewA(maxHeight: maxHeight), visibleA,
            viewB(maxHeight: maxHeight), visibleB,
            e, visible
        )
        return LiquidMorphFrame(
            halfHeight: visible / 2,
            view: LiquidView.squareToQuad(quad),
            motion: e,
            blend: LiquidEase.step(0.12, 0.88, t),
            quickBlend: LiquidEase.step(0.3, 0.7, t)
        )
    }

    /// A photo at rest, `height` tall.
    static func resting(height: Double, maxHeight: Double) -> LiquidMorphFrame {
        let quad = band(height: height, maxHeight: maxHeight)
        return LiquidMorphFrame(
            halfHeight: min(height, maxHeight) / 2,
            view: LiquidView.squareToQuad(quad),
            motion: 0,
            blend: 0
        )
    }
}

/// Camera quads: their interpolation and their projective maps.
enum LiquidView {
    /// Corners are top-left, top-right, bottom-right, bottom-left.
    struct Similarity {
        var center: SIMD2<Double>
        var width: Double
        var angle: Double
    }

    static func similarity(of q: [SIMD2<Double>]) -> Similarity {
        let center = (q[0] + q[1] + q[2] + q[3]) / 4
        let top = q[1] - q[0], bottom = q[2] - q[3]
        let direction = top + bottom
        return Similarity(
            center: center,
            width: (simd_length(top) + simd_length(bottom)) / 2,
            angle: atan2(direction.y, direction.x)
        )
    }

    /// A rectangle `width` wide and `width × height` tall, turned by `angle`.
    static func rectangle(_ s: Similarity, height: Double) -> [SIMD2<Double>] {
        let c = cos(s.angle), n = sin(s.angle)
        return [SIMD2(-0.5, -height / 2), SIMD2(0.5, -height / 2), SIMD2(0.5, height / 2), SIMD2(-0.5, height / 2)].map {
            s.center + SIMD2($0.x * c - $0.y * n, $0.x * n + $0.y * c) * s.width
        }
    }

    /// The camera `e` of the way from quad `a` to quad `b`: centre and turn
    /// eased, size interpolated logarithmically, and whatever perspective the
    /// quads carry beyond a rectangle blended across.
    static func interpolate(
        _ a: [SIMD2<Double>], _ heightA: Double,
        _ b: [SIMD2<Double>], _ heightB: Double,
        _ e: Double, _ height: Double
    ) -> [SIMD2<Double>] {
        let sa = similarity(of: a), sb = similarity(of: b)
        let ra = rectangle(sa, height: heightA), rb = rectangle(sb, height: heightB)
        var turn = sb.angle - sa.angle
        turn = atan2(sin(turn), cos(turn))
        let s = Similarity(
            center: sa.center + (sb.center - sa.center) * e,
            width: sa.width * pow(sb.width / sa.width, e),
            angle: sa.angle + turn * e
        )
        let base = rectangle(s, height: height)
        return (0..<4).map { i in
            let residualA = (a[i] - ra[i]) / sa.width
            let residualB = (b[i] - rb[i]) / sb.width
            return base[i] + (residualA + (residualB - residualA) * e) * s.width
        }
    }

    /// The projective map taking the unit square's corners (0,0), (1,0),
    /// (1,1), (0,1) to `q`'s (Heckbert).
    static func squareToQuad(_ q: [SIMD2<Double>]) -> simd_double3x3 {
        let (p0, p1, p2, p3) = (q[0], q[1], q[2], q[3])
        let d1 = p1 - p2, d2 = p3 - p2, d3 = p0 - p1 + p2 - p3
        var g = 0.0, h = 0.0
        if abs(d3.x) > 1e-12 || abs(d3.y) > 1e-12 {
            let den = d1.x * d2.y - d2.x * d1.y
            g = (d3.x * d2.y - d2.x * d3.y) / den
            h = (d1.x * d3.y - d3.x * d1.y) / den
        }
        return simd_double3x3(rows: [
            SIMD3(p1.x - p0.x + g * p1.x, p3.x - p0.x + h * p3.x, p0.x),
            SIMD3(p1.y - p0.y + g * p1.y, p3.y - p0.y + h * p3.y, p0.y),
            SIMD3(g, h, 1),
        ])
    }
}

/// Applies a projective map to a point.
func project(_ m: simd_double3x3, _ p: SIMD2<Double>) -> SIMD2<Double> {
    let r = m * SIMD3(p.x, p.y, 1)
    return SIMD2(r.x, r.y) / r.z
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
}
