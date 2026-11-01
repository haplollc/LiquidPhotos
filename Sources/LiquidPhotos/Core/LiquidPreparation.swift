//
//  LiquidPreparation.swift
//  LiquidPhotos
//
//  Everything worked out about photos before they can take part in a
//  transition, off the main thread: an upright, downscaled copy for the GPU
//  and a small thumbnail for each photo; for each pair, where one sits
//  inside the other and how every pixel moves between them.
//

import CoreGraphics
import Metal
import MetalKit
import UIKit
import simd

/// `@unchecked` boxes for values that are immutable once made but not
/// marked Sendable by their frameworks.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

/// A photo ready for the stage, minus its texture.
struct LiquidPhotoInfo: Sendable {
    /// Width over height, upright.
    let aspect: Double
    /// About 160 px wide: luma and two opponent chroma planes, 0...1.
    let thumbnail: FlowImage

    /// Height in widths.
    var height: Double { 1 / max(aspect, 0.05) }
}

enum LiquidPreparation {
    /// Draws `image` upright into an sRGB bitmap at most `maxPixelSize` on
    /// its long side.
    static func uprightImage(_ image: UIImage, maxPixelSize: Int) -> CGImage? {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }
        let shrink = min(1, CGFloat(maxPixelSize) / max(pixels.width, pixels.height))
        let size = CGSize(width: max(1, (pixels.width * shrink).rounded()), height: max(1, (pixels.height * shrink).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
    }

    /// Reads a photo's shape and its thumbnail for alignment and flow.
    static func info(for image: CGImage) -> LiquidPhotoInfo? {
        let aspect = Double(image.width) / Double(max(image.height, 1))
        return LiquidPhotoInfo(aspect: aspect, thumbnail: flowThumbnail(of: image, width: 160))
    }

    /// A texture with a full mip chain, so the shader can defocus cheaply.
    static func texture(from image: CGImage, device: MTLDevice) throws -> MTLTexture {
        let loader = MTKTextureLoader(device: device)
        return try loader.newTexture(cgImage: image, options: [
            .SRGB: false,
            .generateMipmaps: true,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
        ])
    }

    // MARK: Flow

    /// A `width`-pixel-wide copy in luma + opponent chroma, values 0...1.
    static func flowThumbnail(of image: CGImage, width: Int) -> FlowImage {
        let w = max(8, width)
        let h = max(8, Int((Double(w) * Double(image.height) / Double(max(image.width, 1))).rounded()))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        var out = FlowImage(width: w, height: h, channels: 3)
        guard drawn else { return out }
        for i in 0..<(w * h) {
            let r = Float(bytes[i * 4]) / 255, g = Float(bytes[i * 4 + 1]) / 255, b = Float(bytes[i * 4 + 2]) / 255
            out.planes[0][i] = 0.299 * r + 0.587 * g + 0.114 * b
            out.planes[1][i] = 0.5 + 0.5 * (r - g)
            out.planes[2][i] = 0.5 + 0.5 * (0.5 * (r + g) - b)
        }
        return out
    }

    // MARK: Pairs

    /// Places photo `b` in photo `a`'s world and works out how every pixel
    /// moves between them.
    static func morph(_ a: LiquidPhotoInfo, _ b: LiquidPhotoInfo) -> (LiquidMorph, LiquidMorphFlow) {
        let (toB, related) = alignment(a, b)
        let morph = LiquidMorph(heightA: a.height, heightB: b.height, toB: toB, related: related)
        // Related photos have real motion to follow, so they get a finer field.
        return (morph, flow(a, b, morph, gridLongSide: related ? 176 : 128))
    }

    /// World → `b`'s coordinates, and whether `b` really is `a`'s scene.
    ///
    /// Searches for where one photo sits inside the other, as a scaled and
    /// shifted window (a close-up is a small window, a step aside a shifted
    /// one), both ways round, keeping whichever matches best.
    static func alignment(_ a: LiquidPhotoInfo, _ b: LiquidPhotoInfo) -> (simd_double3x3, Bool) {
        let inside = window(of: b, in: a)     // b's view as a window of a
        let around = window(of: a, in: b)     // a's view as a window of b
        if max(inside.score, around.score) > 0.7 {
            if inside.score >= around.score {
                // world → b: (w - origin) / scale
                let k = 1 / inside.scale
                return (simd_double3x3(rows: [SIMD3(k, 0, -inside.origin.x * k), SIMD3(0, k, -inside.origin.y * k), SIMD3(0, 0, 1)]), true)
            }
            // a's point w sits at origin + w × scale in b.
            let k = around.scale
            return (simd_double3x3(rows: [SIMD3(k, 0, around.origin.x), SIMD3(0, k, around.origin.y), SIMD3(0, 0, 1)]), true)
        }
        return (LiquidMorph.centered(heightA: a.height, heightB: b.height), false)
    }

    /// Where `inner` best matches a window of `outer`: the window's top-left
    /// corner and width in `outer`'s units, and the correlation there.
    static func window(of inner: LiquidPhotoInfo, in outer: LiquidPhotoInfo) -> (origin: SIMD2<Double>, scale: Double, score: Double) {
        let coarseInner = inner.thumbnail.halved(), coarseOuter = outer.thumbnail.halved()
        var best: [(origin: SIMD2<Double>, scale: Double, score: Double)] = []

        // Coarse: every scale on a log grid, every shift on a grid that
        // follows the scale, the window allowed to hang 30% off the edge.
        for step in 0..<18 {
            let scale = 0.2 * pow(1.06 / 0.2, Double(step) / 17)
            let stride = scale / 8
            var y = -0.3 * scale * inner.height
            while y <= outer.height - 0.7 * scale * inner.height {
                var x = -0.3 * scale
                while x <= 1 - 0.7 * scale {
                    let score = correlation(coarseInner, inner.height, coarseOuter, outer.height, SIMD2(x, y), scale, grid: 12)
                    if best.count < 4 || score > best[best.count - 1].score {
                        best.append((SIMD2(x, y), scale, score))
                        best.sort { $0.score > $1.score }
                        if best.count > 4 { best.removeLast() }
                    }
                    x += stride
                }
                y += stride
            }
        }

        // Fine: polish the best few with a shrinking pattern search.
        var winner = (origin: SIMD2(0.0, 0.0), scale: 1.0, score: -1.0)
        for start in best {
            var current = start
            current.score = correlation(inner.thumbnail, inner.height, outer.thumbnail, outer.height, current.origin, current.scale, grid: 28)
            var move = current.scale / 12, zoom = 0.06
            for _ in 0..<10 {
                var improved = true
                while improved {
                    improved = false
                    for (dx, dy, dz) in [(1.0, 0.0, 0.0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] {
                        let scale = current.scale * exp(dz * zoom)
                        // Zoom about the window's centre so scale and shift stay independent.
                        let centre = current.origin + SIMD2(0.5, inner.height / 2) * current.scale
                        let origin = centre - SIMD2(0.5, inner.height / 2) * scale + SIMD2(dx, dy) * move
                        let score = correlation(inner.thumbnail, inner.height, outer.thumbnail, outer.height, origin, scale, grid: 28)
                        if score > current.score + 1e-4 {
                            current = (origin, scale, score)
                            improved = true
                        }
                    }
                }
                move /= 2
                zoom /= 2
            }
            if current.score > winner.score { winner = current }
        }
        return winner
    }

    /// Normalised cross-correlation of `inner` with the window of `outer`
    /// at `origin`, `scale` wide, on a `grid`-wide lattice, over luma and
    /// both chroma planes together (so a bright-top, dark-bottom layout alone
    /// doesn't match); -1 when too little of the window lies inside `outer`.
    static func correlation(
        _ inner: FlowImage, _ innerHeight: Double,
        _ outer: FlowImage, _ outerHeight: Double,
        _ origin: SIMD2<Double>, _ scale: Double, grid: Int
    ) -> Double {
        let rows = max(4, Int((Double(grid) * innerHeight).rounded()))
        var points: [(SIMD2<Float>, SIMD2<Float>)] = []
        points.reserveCapacity(grid * rows)
        for j in 0..<rows {
            let v = (Double(j) + 0.5) / Double(rows)
            let wy = (origin.y + v * innerHeight * scale) / outerHeight
            guard wy >= 0, wy <= 1 else { continue }
            for i in 0..<grid {
                let u = (Double(i) + 0.5) / Double(grid)
                let wx = origin.x + u * scale
                guard wx >= 0, wx <= 1 else { continue }
                points.append((
                    SIMD2(Float(u * Double(inner.width) - 0.5), Float(v * Double(inner.height) - 0.5)),
                    SIMD2(Float(wx * Double(outer.width) - 0.5), Float(wy * Double(outer.height) - 0.5))
                ))
            }
        }
        guard Double(points.count) >= 0.6 * Double(grid * rows) else { return -1 }
        let n = Double(points.count)
        var cov = 0.0, varX = 0.0, varY = 0.0
        for c in 0..<min(3, inner.planes.count) {
            var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
            inner.planes[c].withUnsafeBufferPointer { pi in
                outer.planes[c].withUnsafeBufferPointer { po in
                    for (pin, pout) in points {
                        let x = Double(FlowImage.bilinear(pi, inner.width, inner.height, pin.x, pin.y))
                        let y = Double(FlowImage.bilinear(po, outer.width, outer.height, pout.x, pout.y))
                        sx += x; sy += y; sxx += x * x; syy += y * y; sxy += x * y
                    }
                }
            }
            cov += sxy - sx * sy / n
            varX += sxx - sx * sx / n
            varY += syy - sy * sy / n
        }
        return cov / max((varX * varY).squareRoot(), 1e-9)
    }

    /// The flow both ways over the part of the world either photo shows,
    /// with how far each vector can be trusted (forward-backward agreement).
    static func flow(_ a: LiquidPhotoInfo, _ b: LiquidPhotoInfo, _ morph: LiquidMorph, gridLongSide: Int = 128) -> LiquidMorphFlow {
        let viewB = morph.viewB(maxHeight: 100)
        var lo = SIMD2(0.0, 0.0), hi = SIMD2(1.0, a.height)
        for p in viewB {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        lo = simd_max(lo, SIMD2(-1, -a.height))
        hi = simd_min(hi, SIMD2(2, 2 * a.height))
        let pad = (hi - lo) * 0.04
        let origin = lo - pad, size = hi - lo + 2 * pad
        let ratio = size.y / size.x
        let gw = ratio <= 1 ? gridLongSide : max(16, Int((Double(gridLongSide) / ratio).rounded()))
        let gh = ratio <= 1 ? max(16, Int((Double(gridLongSide) * ratio).rounded())) : gridLongSide

        var imageA = FlowImage(width: gw, height: gh, channels: 3), imageB = imageA
        for y in 0..<gh {
            for x in 0..<gw {
                let w = origin + size * SIMD2((Double(x) + 0.5) / Double(gw), (Double(y) + 0.5) / Double(gh))
                let q = project(morph.toB, w)
                let insideA = w.x >= 0 && w.x <= 1 && w.y >= 0 && w.y <= a.height
                let insideB = q.x >= 0 && q.x <= 1 && q.y >= 0 && q.y <= b.height
                for c in 0..<3 {
                    let va = a.thumbnail.sampleMirrored(c, Float(w.x), Float(w.y / a.height))
                    let vb = b.thumbnail.sampleMirrored(c, Float(q.x), Float(q.y / b.height))
                    // Where only one photo has pixels, the other copies it, so
                    // nothing pulls the flow there but its neighbours.
                    imageA.planes[c][y * gw + x] = insideA ? va : vb
                    imageB.planes[c][y * gw + x] = insideB ? vb : va
                }
            }
        }
        imageA = imageA.smoothed(passes: 1).normalized()
        imageB = imageB.smoothed(passes: 1).normalized()

        var parameters = LiquidFlowSolver.Parameters()
        if morph.related {
            // Real correspondences: let the field follow them closely.
            parameters.smoothness = 0.35
            parameters.iterations = 60
            parameters.warps = 4
            parameters.maxDisplacement = 0.12
        }
        let ab = LiquidFlowSolver.flow(from: imageA, to: imageB, parameters: parameters)
        let ba = LiquidFlowSolver.flow(from: imageB, to: imageA, parameters: parameters)

        func pack(_ f: FlowVectors, _ g: FlowVectors) -> [Float] {
            var out = [Float](repeating: 0, count: gw * gh * 4)
            let sx = Float(size.x) / Float(gw), sy = Float(size.y) / Float(gh)
            g.u.withUnsafeBufferPointer { gu in
                g.v.withUnsafeBufferPointer { gv in
                    for y in 0..<gh {
                        for x in 0..<gw {
                            let i = y * gw + x
                            let fx = f.u[i], fy = f.v[i]
                            // Where this pixel lands, the other flow should point back.
                            let bx = FlowImage.bilinear(gu, gw, gh, Float(x) + fx, Float(y) + fy)
                            let by = FlowImage.bilinear(gv, gw, gh, Float(x) + fx, Float(y) + fy)
                            let miss = (fx + bx) * (fx + bx) + (fy + by) * (fy + by)
                            out[i * 4 + 0] = fx * sx
                            out[i * 4 + 1] = fy * sy
                            out[i * 4 + 2] = exp(-miss / (2 * 1.5 * 1.5))
                        }
                    }
                }
            }
            return out
        }
        return LiquidMorphFlow(
            width: gw, height: gh,
            origin: SIMD2(Float(origin.x), Float(origin.y)),
            size: SIMD2(Float(size.x), Float(size.y)),
            ab: pack(ab, ba), ba: pack(ba, ab)
        )
    }
}

/// The flow between a pair of photos on a grid over the world.
struct LiquidMorphFlow: Sendable {
    let width: Int
    let height: Int
    /// World position of the grid's top-left corner.
    let origin: SIMD2<Float>
    /// World extent of the grid.
    let size: SIMD2<Float>
    /// Per cell, first → second: the move (world units) and its confidence.
    let ab: [Float]
    /// Per cell, second → first.
    let ba: [Float]

    func textures(device: MTLDevice) -> (MTLTexture, MTLTexture)? {
        func make(_ data: [Float]) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            let halves = data.map { Float16($0) }
            halves.withUnsafeBytes { raw in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: raw.baseAddress!, bytesPerRow: width * 4 * MemoryLayout<Float16>.size
                )
            }
            return texture
        }
        guard let ab = make(ab), let ba = make(ba) else { return nil }
        return (ab, ba)
    }
}
