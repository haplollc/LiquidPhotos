//
//  LiquidPreparation.swift
//  LiquidPhotos
//
//  Everything worked out about a photo before it can take part in a
//  transition, off the main thread: an upright, downscaled copy for the GPU,
//  its subject (Vision's attention saliency, or a centre-weighted contrast
//  guess when Vision can't run), and a thumbnail in opponent colours for the
//  flow. Then, per pair, the flow between them in anchor space.
//

import CoreGraphics
import Metal
import MetalKit
import UIKit
import Vision

/// `@unchecked` boxes for values that are immutable once made but not
/// marked Sendable by their frameworks.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

/// A photo ready for the stage, minus its texture.
struct LiquidPhotoInfo: Sendable {
    /// Width over height, upright.
    let aspect: Double
    /// The subject, in unit coordinates with the origin top left.
    let subject: CGRect
    /// About 160 px wide: luma and two opponent chroma planes, 0...1.
    let thumbnail: FlowImage

    var frame: LiquidFrame { LiquidFrame(aspect: aspect, subject: subject) }
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

    /// Reads a photo's shape, subject and flow thumbnail.
    static func info(for image: CGImage) -> LiquidPhotoInfo {
        let aspect = Double(image.width) / Double(max(image.height, 1))
        let thumbnail = flowThumbnail(of: image, width: 160)
        let subject = visionSubject(in: image) ?? contrastSubject(in: thumbnail)
        return LiquidPhotoInfo(aspect: aspect, subject: subject, thumbnail: thumbnail)
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

    // MARK: Subject

    /// The salient region Vision's attention model finds, or nil.
    static func visionSubject(in image: CGImage) -> CGRect? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        guard let objects = observation.salientObjects, let first = objects.first else { return nil }
        var box = first.boundingBox
        for object in objects.dropFirst() where object.confidence >= first.confidence * 0.5 {
            box = box.union(object.boundingBox)
        }
        guard box.width > 0.02, box.height > 0.02 else { return nil }
        // Vision's origin is bottom left.
        return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    /// A guess at the subject without Vision: where colours differ most from
    /// the photo's average, weighted toward the centre.
    static func contrastSubject(in thumbnail: FlowImage) -> CGRect {
        let w = thumbnail.width, h = thumbnail.height
        var mean = [Float](repeating: 0, count: thumbnail.planes.count)
        for c in thumbnail.planes.indices {
            mean[c] = thumbnail.planes[c].reduce(0, +) / Float(w * h)
        }
        var total: Float = 0, sx: Float = 0, sy: Float = 0, sxx: Float = 0, syy: Float = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                var d: Float = 0
                for c in thumbnail.planes.indices {
                    let e = thumbnail.planes[c][i] - mean[c]
                    d += e * e
                }
                let u = (Float(x) + 0.5) / Float(w) - 0.5
                let v = (Float(y) + 0.5) / Float(h) - 0.5
                let weight = d.squareRoot() * exp(-(u * u + v * v) / (2 * 0.3 * 0.3))
                total += weight
                sx += weight * u
                sy += weight * v
                sxx += weight * u * u
                syy += weight * v * v
            }
        }
        guard total > 1e-5 else { return CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5) }
        let cx = sx / total, cy = sy / total
        let spreadX = max(0.1, (sxx / total - cx * cx).squareRoot() * 2.2)
        let spreadY = max(0.1, (syy / total - cy * cy).squareRoot() * 2.2)
        return CGRect(
            x: CGFloat(cx + 0.5 - spreadX / 2),
            y: CGFloat(cy + 0.5 - spreadY / 2),
            width: CGFloat(spreadX),
            height: CGFloat(spreadY)
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
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

    /// The flow between two photos in their shared anchor space, both ways,
    /// as RGBA (a→b in xy, b→a in zw), in anchor-space units.
    static func pairFlow(
        _ a: LiquidPhotoInfo,
        _ b: LiquidPhotoInfo,
        geometry: LiquidPairGeometry,
        gridLongSide: Int = 64
    ) -> LiquidPairFlow {
        let window = geometry.flowWindow(maxHeight: 100)
        let ratio = window.size.y / window.size.x
        let gw = ratio <= 1 ? gridLongSide : max(12, Int((Double(gridLongSide) / ratio).rounded()))
        let gh = ratio <= 1 ? max(12, Int((Double(gridLongSide) * ratio).rounded())) : gridLongSide

        func raster(_ info: LiquidPhotoInfo, _ frame: LiquidFrame, _ size: Double) -> FlowImage {
            var img = FlowImage(width: gw, height: gh, channels: info.thumbnail.planes.count)
            for y in 0..<gh {
                for x in 0..<gw {
                    let eta = window.origin + window.size * SIMD2((Double(x) + 0.5) / Double(gw), (Double(y) + 0.5) / Double(gh))
                    let q = frame.anchor + eta * size
                    let u = Float(q.x + 0.5), v = Float(q.y / frame.height + 0.5)
                    for c in img.planes.indices {
                        img.planes[c][y * gw + x] = info.thumbnail.sampleMirrored(c, u, v)
                    }
                }
            }
            return img.smoothed(passes: 1).normalized()
        }

        let imageA = raster(a, geometry.a, geometry.sizeA)
        let imageB = raster(b, geometry.b, geometry.sizeB)
        let ab = LiquidFlowSolver.flow(from: imageA, to: imageB)
        let ba = LiquidFlowSolver.flow(from: imageB, to: imageA)

        let toEta = SIMD2(Float(window.size.x) / Float(gw), Float(window.size.y) / Float(gh))
        var vectors = [Float](repeating: 0, count: gw * gh * 4)
        for i in 0..<(gw * gh) {
            vectors[i * 4 + 0] = ab.u[i] * toEta.x
            vectors[i * 4 + 1] = ab.v[i] * toEta.y
            vectors[i * 4 + 2] = ba.u[i] * toEta.x
            vectors[i * 4 + 3] = ba.v[i] * toEta.y
        }
        return LiquidPairFlow(
            width: gw, height: gh,
            origin: SIMD2(Float(window.origin.x), Float(window.origin.y)),
            size: SIMD2(Float(window.size.x), Float(window.size.y)),
            vectors: vectors
        )
    }
}

/// The flow between a pair of photos on a grid over anchor space.
struct LiquidPairFlow: Sendable {
    let width: Int
    let height: Int
    /// Anchor-space position of the grid's top-left corner.
    let origin: SIMD2<Float>
    /// Anchor-space extent of the grid.
    let size: SIMD2<Float>
    /// RGBA per cell: a→b in xy, b→a in zw.
    let vectors: [Float]

    func texture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let halves = vectors.map { Float16($0) }
        halves.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: width * 4 * MemoryLayout<Float16>.size
            )
        }
        return texture
    }
}
