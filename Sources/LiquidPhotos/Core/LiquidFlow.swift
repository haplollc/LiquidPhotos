//
//  LiquidFlow.swift
//  LiquidPhotos
//
//  The "liquid" in a transition: a dense optical flow between the two
//  photos, so the colour masses of one slide into the matching ones of the
//  next instead of simply fading. Horn–Schunck, coarse to fine with warping,
//  on small planar images, so it runs in a few milliseconds on the CPU.
//
//  Two different photos never really correspond, so the flow is kept very
//  smooth: it moves broad regions (sky to sky, a subject to a subject, dark
//  ground to dark ground) rather than tracking texture.
//

import Foundation

/// A small planar float image the flow works on.
struct FlowImage: Sendable {
    var width: Int
    var height: Int
    /// One plane per channel, row-major, `width * height` each.
    var planes: [[Float]]

    init(width: Int, height: Int, planes: [[Float]]) {
        self.width = width
        self.height = height
        self.planes = planes
    }

    init(width: Int, height: Int, channels: Int) {
        self.init(
            width: width,
            height: height,
            planes: Array(repeating: [Float](repeating: 0, count: width * height), count: channels)
        )
    }

    /// Bilinear sample of one channel at pixel-centre coordinates, clamped
    /// to the border.
    func sample(_ channel: Int, _ x: Float, _ y: Float) -> Float {
        planes[channel].withUnsafeBufferPointer { FlowImage.bilinear($0, width, height, x, y) }
    }

    /// Bilinear sample of one channel in normalised coordinates (0...1 across
    /// the image), mirrored outside it so content never runs out.
    func sampleMirrored(_ channel: Int, _ u: Float, _ v: Float) -> Float {
        let x = FlowImage.mirror(u) * Float(width) - 0.5
        let y = FlowImage.mirror(v) * Float(height) - 0.5
        return sample(channel, x, y)
    }

    static func mirror(_ t: Float) -> Float {
        let period = t.truncatingRemainder(dividingBy: 2)
        let wrapped = period < 0 ? period + 2 : period
        return wrapped > 1 ? 2 - wrapped : wrapped
    }

    @inline(__always)
    static func bilinear(_ p: UnsafeBufferPointer<Float>, _ w: Int, _ h: Int, _ x: Float, _ y: Float) -> Float {
        let cx = min(max(x, 0), Float(w - 1))
        let cy = min(max(y, 0), Float(h - 1))
        let x0 = Int(cx), y0 = Int(cy)
        let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        let fx = cx - Float(x0), fy = cy - Float(y0)
        let a = p[y0 * w + x0], b = p[y0 * w + x1]
        let c = p[y1 * w + x0], d = p[y1 * w + x1]
        let top = a + (b - a) * fx
        let bottom = c + (d - c) * fx
        return top + (bottom - top) * fy
    }

    /// Half the size, each pixel the mean of the 2×2 block above it.
    func halved() -> FlowImage {
        let nw = max(1, (width + 1) / 2), nh = max(1, (height + 1) / 2)
        var out = FlowImage(width: nw, height: nh, channels: planes.count)
        for c in planes.indices {
            planes[c].withUnsafeBufferPointer { src in
                out.planes[c].withUnsafeMutableBufferPointer { dst in
                    for y in 0..<nh {
                        let y0 = min(2 * y, height - 1), y1 = min(2 * y + 1, height - 1)
                        for x in 0..<nw {
                            let x0 = min(2 * x, width - 1), x1 = min(2 * x + 1, width - 1)
                            dst[y * nw + x] = 0.25 * (src[y0 * width + x0] + src[y0 * width + x1]
                                + src[y1 * width + x0] + src[y1 * width + x1])
                        }
                    }
                }
            }
        }
        return out
    }

    /// A separable [1 2 1]/4 blur, `passes` times.
    func smoothed(passes: Int) -> FlowImage {
        var out = self
        guard passes > 0 else { return out }
        let w = width, h = height
        var scratch = [Float](repeating: 0, count: w * h)
        for c in planes.indices {
            for _ in 0..<passes {
                out.planes[c].withUnsafeMutableBufferPointer { img in
                    scratch.withUnsafeMutableBufferPointer { tmp in
                        for y in 0..<h {
                            for x in 0..<w {
                                let l = img[y * w + max(x - 1, 0)], r = img[y * w + min(x + 1, w - 1)]
                                tmp[y * w + x] = 0.25 * l + 0.5 * img[y * w + x] + 0.25 * r
                            }
                        }
                        for y in 0..<h {
                            for x in 0..<w {
                                let u = tmp[max(y - 1, 0) * w + x], d = tmp[min(y + 1, h - 1) * w + x]
                                img[y * w + x] = 0.25 * u + 0.5 * tmp[y * w + x] + 0.25 * d
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Each channel shifted to zero mean and scaled to unit spread, so two
    /// photos are compared by their structure, not their exposure.
    func normalized() -> FlowImage {
        var out = self
        for c in planes.indices {
            let n = Float(planes[c].count)
            let mean = planes[c].reduce(0, +) / n
            let variance = planes[c].reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
            let scale = 1 / max(variance.squareRoot(), 0.02)
            out.planes[c] = planes[c].map { ($0 - mean) * scale }
        }
        return out
    }
}

/// A flow field on a grid: per pixel, where that pixel's content went, in
/// pixels of the grid.
struct FlowVectors: Sendable {
    var width: Int
    var height: Int
    var u: [Float]
    var v: [Float]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        u = [Float](repeating: 0, count: width * height)
        v = [Float](repeating: 0, count: width * height)
    }

    /// Bilinear resample to a new grid, scaling the vectors with it.
    func resized(width nw: Int, height nh: Int) -> FlowVectors {
        var out = FlowVectors(width: nw, height: nh)
        let sx = Float(width) / Float(nw), sy = Float(height) / Float(nh)
        let gain = (x: Float(nw) / Float(width), y: Float(nh) / Float(height))
        u.withUnsafeBufferPointer { su in
            v.withUnsafeBufferPointer { sv in
                for y in 0..<nh {
                    for x in 0..<nw {
                        let fx = (Float(x) + 0.5) * sx - 0.5
                        let fy = (Float(y) + 0.5) * sy - 0.5
                        out.u[y * nw + x] = FlowImage.bilinear(su, width, height, fx, fy) * gain.x
                        out.v[y * nw + x] = FlowImage.bilinear(sv, width, height, fx, fy) * gain.y
                    }
                }
            }
        }
        return out
    }
}

/// Horn–Schunck optical flow, coarse to fine with warping.
enum LiquidFlowSolver {
    struct Parameters: Sendable {
        /// The smoothness weight. Larger keeps the field smoother and calmer.
        var smoothness: Float = 1.6
        /// Jacobi sweeps per warp.
        var iterations: Int = 45
        /// Times each level re-warps and re-linearises.
        var warps: Int = 3
        /// Levels of the pyramid, coarsest first, until a side gets this small.
        var coarsestSide: Int = 6
        /// Per-channel weights in the data term.
        var channelWeights: [Float] = [1, 0.6, 0.6]
        /// The largest vector allowed, as a fraction of the grid's width.
        var maxDisplacement: Float = 0.2
    }

    /// The flow from `a` to `b`: content at `x` in `a` is found at
    /// `x + flow(x)` in `b`. Both images must have the same size.
    static func flow(from a: FlowImage, to b: FlowImage, parameters: Parameters = .init()) -> FlowVectors {
        precondition(a.width == b.width && a.height == b.height && a.planes.count == b.planes.count)

        var pyramidA = [a], pyramidB = [b]
        while let last = pyramidA.last, min(last.width, last.height) / 2 >= parameters.coarsestSide {
            pyramidA.append(last.halved())
            pyramidB.append(pyramidB.last!.halved())
        }

        var flow = FlowVectors(width: pyramidA.last!.width, height: pyramidA.last!.height)
        for level in stride(from: pyramidA.count - 1, through: 0, by: -1) {
            let la = pyramidA[level], lb = pyramidB[level]
            if flow.width != la.width || flow.height != la.height {
                flow = flow.resized(width: la.width, height: la.height)
            }
            refine(&flow, a: la, b: lb, parameters: parameters)
        }
        return flow
    }

    /// Warping iterations at one level of the pyramid.
    private static func refine(_ flow: inout FlowVectors, a: FlowImage, b: FlowImage, parameters p: Parameters) {
        let w = a.width, h = a.height, n = w * h
        let alpha2 = p.smoothness * p.smoothness
        let limit = p.maxDisplacement * Float(w)

        var j11 = [Float](repeating: 0, count: n), j12 = j11, j22 = j11, b1 = j11, b2 = j11
        var du = j11, dv = j11, nu = j11, nv = j11, meanU = j11, meanV = j11
        var warped = [Float](repeating: 0, count: n)

        for _ in 0..<p.warps {
            for i in 0..<n { j11[i] = 0; j12[i] = 0; j22[i] = 0; b1[i] = 0; b2[i] = 0 }

            for c in a.planes.indices {
                let weight = c < p.channelWeights.count ? p.channelWeights[c] : 1
                b.planes[c].withUnsafeBufferPointer { pb in
                    flow.u.withUnsafeBufferPointer { fu in
                        flow.v.withUnsafeBufferPointer { fv in
                            warped.withUnsafeMutableBufferPointer { out in
                                for y in 0..<h {
                                    for x in 0..<w {
                                        let i = y * w + x
                                        out[i] = FlowImage.bilinear(pb, w, h, Float(x) + fu[i], Float(y) + fv[i])
                                    }
                                }
                            }
                        }
                    }
                }
                a.planes[c].withUnsafeBufferPointer { pa in
                    warped.withUnsafeBufferPointer { pw in
                        for y in 0..<h {
                            let ym = max(y - 1, 0), yp = min(y + 1, h - 1)
                            for x in 0..<w {
                                let xm = max(x - 1, 0), xp = min(x + 1, w - 1)
                                let i = y * w + x
                                let ix = 0.25 * (pa[y * w + xp] - pa[y * w + xm] + pw[y * w + xp] - pw[y * w + xm])
                                let iy = 0.25 * (pa[yp * w + x] - pa[ym * w + x] + pw[yp * w + x] - pw[ym * w + x])
                                let it = pw[i] - pa[i]
                                j11[i] += weight * ix * ix
                                j12[i] += weight * ix * iy
                                j22[i] += weight * iy * iy
                                b1[i] += weight * ix * it
                                b2[i] += weight * iy * it
                            }
                        }
                    }
                }
            }

            neighbourMean(flow.u, w, h, into: &meanU)
            neighbourMean(flow.v, w, h, into: &meanV)
            for i in 0..<n { du[i] = 0; dv[i] = 0 }

            for _ in 0..<p.iterations {
                du.withUnsafeBufferPointer { cu in
                    dv.withUnsafeBufferPointer { cv in
                        nu.withUnsafeMutableBufferPointer { ou in
                            nv.withUnsafeMutableBufferPointer { ov in
                                for y in 0..<h {
                                    let ym = max(y - 1, 0), yp = min(y + 1, h - 1)
                                    for x in 0..<w {
                                        let xm = max(x - 1, 0), xp = min(x + 1, w - 1)
                                        let i = y * w + x
                                        let au = 0.25 * (cu[y * w + xm] + cu[y * w + xp] + cu[ym * w + x] + cu[yp * w + x])
                                        let av = 0.25 * (cv[y * w + xm] + cv[y * w + xp] + cv[ym * w + x] + cv[yp * w + x])
                                        // Smoothness pulls the total flow toward its
                                        // neighbours; the data term pulls toward a match.
                                        let r1 = alpha2 * (meanU[i] + au - flow.u[i]) - b1[i]
                                        let r2 = alpha2 * (meanV[i] + av - flow.v[i]) - b2[i]
                                        let m11 = j11[i] + alpha2, m22 = j22[i] + alpha2, m12 = j12[i]
                                        let det = m11 * m22 - m12 * m12
                                        ou[i] = (m22 * r1 - m12 * r2) / det
                                        ov[i] = (m11 * r2 - m12 * r1) / det
                                    }
                                }
                            }
                        }
                    }
                }
                swap(&du, &nu)
                swap(&dv, &nv)
            }

            for i in 0..<n {
                var u = flow.u[i] + du[i], v = flow.v[i] + dv[i]
                let length = (u * u + v * v).squareRoot()
                if length > limit {
                    u *= limit / length
                    v *= limit / length
                }
                flow.u[i] = u
                flow.v[i] = v
            }
        }
    }

    private static func neighbourMean(_ field: [Float], _ w: Int, _ h: Int, into out: inout [Float]) {
        field.withUnsafeBufferPointer { f in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<h {
                    let ym = max(y - 1, 0), yp = min(y + 1, h - 1)
                    for x in 0..<w {
                        let xm = max(x - 1, 0), xp = min(x + 1, w - 1)
                        o[y * w + x] = 0.25 * (f[y * w + xm] + f[y * w + xp] + f[ym * w + x] + f[yp * w + x])
                    }
                }
            }
        }
    }
}
