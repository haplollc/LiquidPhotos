//
//  LiquidMesh.swift
//  LiquidPhotos
//
//  How the parts of one photo travel to their places in the next.
//
//  A dense flow proposes where everything went; only the proposals whose
//  patches really look alike in both photos are kept. A grid mesh is then
//  fitted to those matches with a similarity term asking every triangle to
//  keep its shape: the content-preserving warp of Liu, Gleicher, Jin &
//  Agarwala (2009), as After Effects' Warp Stabilizer uses it. Matched
//  regions therefore move, scale and turn as solid pieces, and regions with
//  no match follow their neighbours rigidly instead of swirling. Each vertex
//  also carries the local colour shift between the photos, so a region that
//  is the same thing in different light re-tints as it moves.
//

import Foundation
import simd

/// One mesh vertex as the GPU reads it (64 bytes, matching `LiquidMeshVertex`
/// in the shader).
struct LiquidMeshVertex {
    /// Where this bit of picture is in the first photo's world.
    var worldA: SIMD2<Float>
    /// Where it is in the second photo, in the same world.
    var worldB: SIMD2<Float>
    /// Its texture coordinates in the first photo.
    var uvA: SIMD2<Float>
    /// Its texture coordinates in the second photo.
    var uvB: SIMD2<Float>
    /// Per-channel gain taking the first photo's colours to the second's;
    /// `w` is how sure the match is here (0 none, 1 certain).
    var gain: SIMD4<Float>
    /// Per-channel offset of that colour shift.
    var offset: SIMD4<Float>
}

/// The fitted mesh of a pair: `(columns + 1) × (rows + 1)` vertices.
struct LiquidMeshData: Sendable {
    let columns: Int
    let rows: Int
    let vertices: [LiquidMeshVertex]
    /// Two triangles per cell.
    let indices: [UInt16]
    /// Verified correspondences the fit used.
    let matchCount: Int
}

extension LiquidMeshVertex: @unchecked Sendable {}

enum LiquidMeshFit {
    struct Match {
        /// World position in the first photo.
        var a: SIMD2<Double>
        /// Position in the second photo's own units.
        var b: SIMD2<Double>
        var weight: Double
    }

    /// Fits the mesh for a pair whose global placement is `morph` and whose
    /// dense flow (world units, both ways) proposes the correspondences.
    static func fit(
        _ a: LiquidPhotoInfo, _ b: LiquidPhotoInfo,
        _ morph: LiquidMorph, flow: LiquidMorphFlow
    ) -> LiquidMeshData {
        let origin = SIMD2(Double(flow.origin.x), Double(flow.origin.y))
        let size = SIMD2(Double(flow.size.x), Double(flow.size.y))
        let columns = 24
        let rows = min(40, max(8, Int((Double(columns) * size.y / size.x).rounded())))

        let span = SIMD2(Double(columns), Double(rows))
        func node(_ i: Int, _ j: Int) -> SIMD2<Double> {
            let t = SIMD2(Double(i), Double(j)) / span
            return origin + t * size
        }
        let matches = morph.related ? verifiedMatches(a, b, morph, flow) : []
        let positions = solve(columns, rows, origin, size, morph.toB, matches)

        // Confidence per vertex: the match weight in its neighbourhood.
        var confidence = [Double](repeating: 0, count: (columns + 1) * (rows + 1))
        for m in matches {
            let g = (m.a - origin) / size * span
            let ci = min(max(Int(g.x.rounded()), 0), columns), cj = min(max(Int(g.y.rounded()), 0), rows)
            confidence[cj * (columns + 1) + ci] += m.weight
        }
        confidence = smoothed(confidence, columns + 1, rows + 1, passes: 2).map { min($0 / 0.8, 1) }

        // Colour shift per vertex, measured where the photos match.
        var gains = [SIMD3<Double>](repeating: SIMD3(1, 1, 1), count: confidence.count)
        var offsets = [SIMD3<Double>](repeating: .zero, count: confidence.count)
        let fromB = morph.toB.inverse
        let cell = size.x / Double(columns)
        for j in 0...rows {
            for i in 0...columns {
                let k = j * (columns + 1) + i
                guard confidence[k] > 0.05 else { continue }
                let pa = node(i, j)
                if let (g, o) = colourShift(a, b, at: pa, matchedTo: positions[k], radius: cell * 0.9, toB: morph.toB) {
                    gains[k] = g
                    offsets[k] = o
                }
            }
        }
        // Spread the measured shifts softly into their surroundings.
        for _ in 0..<3 {
            let g0 = gains, o0 = offsets
            for j in 0...rows {
                for i in 0...columns {
                    let k = j * (columns + 1) + i
                    guard confidence[k] < 0.95 else { continue }
                    var sg = SIMD3<Double>.zero, so = SIMD3<Double>.zero, sw = 0.0
                    for (di, dj) in [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let ni = i + di, nj = j + dj
                        guard ni >= 0, ni <= columns, nj >= 0, nj <= rows else { continue }
                        let n = nj * (columns + 1) + ni
                        let w = (di == 0 && dj == 0 ? 1 : 0.5) * max(confidence[n], 0.02)
                        sg += g0[n] * SIMD3(repeating: w)
                        so += o0[n] * SIMD3(repeating: w)
                        sw += w
                    }
                    gains[k] = sg / sw
                    offsets[k] = so / sw
                }
            }
        }

        var vertices: [LiquidMeshVertex] = []
        vertices.reserveCapacity(confidence.count)
        for j in 0...rows {
            for i in 0...columns {
                let k = j * (columns + 1) + i
                let wa = node(i, j)
                let qb = positions[k]
                let wb = project(fromB, qb)
                vertices.append(LiquidMeshVertex(
                    worldA: SIMD2(Float(wa.x), Float(wa.y)),
                    worldB: SIMD2(Float(wb.x), Float(wb.y)),
                    uvA: SIMD2(Float(wa.x), Float(wa.y / a.height)),
                    uvB: SIMD2(Float(qb.x), Float(qb.y / b.height)),
                    gain: SIMD4(Float(gains[k].x), Float(gains[k].y), Float(gains[k].z), Float(confidence[k])),
                    offset: SIMD4(Float(offsets[k].x), Float(offsets[k].y), Float(offsets[k].z), 0)
                ))
            }
        }
        var indices: [UInt16] = []
        for j in 0..<rows {
            for i in 0..<columns {
                let v00 = UInt16(j * (columns + 1) + i), v10 = v00 + 1
                let v01 = UInt16((j + 1) * (columns + 1) + i), v11 = v01 + 1
                indices += [v00, v10, v11, v00, v11, v01]
            }
        }
        return LiquidMeshData(columns: columns, rows: rows, vertices: vertices, indices: indices, matchCount: matches.count)
    }

    // MARK: Matches

    /// Flow proposals on a lattice over the first photo, each refined and
    /// kept only if its neighbourhood looks the same in both photos.
    static func verifiedMatches(_ a: LiquidPhotoInfo, _ b: LiquidPhotoInfo, _ morph: LiquidMorph, _ flow: LiquidMorphFlow) -> [Match] {
        let px = 1.0 / Double(a.detail.width)            // one detail pixel, in world widths
        let radius = 3                                    // 7 × 7 patches
        let lattice = 48
        var matches: [Match] = []
        let fo = SIMD2(Double(flow.origin.x), Double(flow.origin.y)), fs = SIMD2(Double(flow.size.x), Double(flow.size.y))

        func flowAB(_ w: SIMD2<Double>) -> SIMD2<Double> {
            let g = (w - fo) / fs * SIMD2(Double(flow.width), Double(flow.height)) - 0.5
            let x = min(max(g.x, 0), Double(flow.width - 1)), y = min(max(g.y, 0), Double(flow.height - 1))
            let x0 = Int(x), y0 = Int(y), x1 = min(x0 + 1, flow.width - 1), y1 = min(y0 + 1, flow.height - 1)
            let fx = x - Double(x0), fy = y - Double(y0)
            func at(_ xi: Int, _ yi: Int) -> SIMD2<Double> {
                let i = (yi * flow.width + xi) * 4
                return SIMD2(Double(flow.ab[i]), Double(flow.ab[i + 1]))
            }
            return (at(x0, y0) * (1 - fx) + at(x1, y0) * fx) * (1 - fy) + (at(x0, y1) * (1 - fx) + at(x1, y1) * fx) * fy
        }

        var sa = [Float](repeating: 0, count: 147), sb = sa
        let rows = max(4, Int(Double(lattice) * a.height))
        for j in 0..<rows {
            for i in 0..<lattice {
                let p = SIMD2((Double(i) + 0.5) / Double(lattice), (Double(j) + 0.5) / Double(rows) * a.height)
                guard samples(a.detail, a.height, p, px, radius, nil, &sa), texture(sa) > 0.0025 else { continue }
                // Around the flow's proposal: a coarse look, then a fine one.
                let proposal = p + flowAB(p)
                var best = (score: -1.0, at: proposal)
                for (span, step) in [(2, 2.0), (1, 1.0)] {
                    let centre = best.at
                    for dy in -span...span {
                        for dx in -span...span {
                            let c = centre + SIMD2(Double(dx), Double(dy)) * px * step
                            guard samples(b.detail, b.height, c, px, radius, morph.toB, &sb) else { continue }
                            let score = ncc(sa, sb)
                            if score > best.score { best = (score, c) }
                        }
                    }
                }
                guard best.score >= 0.8 else { continue }
                matches.append(Match(a: p, b: project(morph.toB, best.at), weight: (best.score - 0.7) / 0.3))
            }
        }
        return matches
    }

    /// RGB samples of a 7 × 7 patch centred on world point `p`, read from a
    /// photo directly or, with `toB`, through the placement. False when the
    /// patch leaves the photo.
    static func samples(
        _ image: FlowImage, _ height: Double, _ p: SIMD2<Double>, _ step: Double, _ r: Int,
        _ toB: simd_double3x3?, _ out: inout [Float]
    ) -> Bool {
        var n = 0
        for dy in -r...r {
            for dx in -r...r {
                var q = p + SIMD2(Double(dx), Double(dy)) * step
                if let toB { q = project(toB, q) }
                guard q.x >= 0, q.x <= 1, q.y >= 0, q.y <= height else { return false }
                let u = Float(q.x) * Float(image.width) - 0.5, v = Float(q.y / height) * Float(image.height) - 0.5
                for c in 0..<3 {
                    out[n] = image.sample(c, u, v)
                    n += 1
                }
            }
        }
        return true
    }

    /// How much a patch varies: flat patches can't be matched reliably.
    static func texture(_ s: [Float]) -> Double {
        let n = Double(s.count)
        let mean = s.reduce(0, +) / Float(s.count)
        return Double(s.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }) / n
    }

    /// Zero-mean normalised cross-correlation of two equal-length samples.
    static func ncc(_ x: [Float], _ y: [Float]) -> Double {
        let n = Float(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy: Float = 0, sxx: Float = 0, syy: Float = 0
        for i in x.indices {
            let a = x[i] - mx, b = y[i] - my
            sxy += a * b; sxx += a * a; syy += b * b
        }
        return Double(sxy / max((sxx * syy).squareRoot(), 1e-6))
    }

    // MARK: The warp

    /// Least-squares mesh positions (in the second photo's units): matches
    /// pull, every triangle resists changing shape, and a weak prior holds
    /// unmatched areas to the global placement.
    static func solve(
        _ columns: Int, _ rows: Int, _ origin: SIMD2<Double>, _ size: SIMD2<Double>,
        _ toB: simd_double3x3, _ matches: [Match]
    ) -> [SIMD2<Double>] {
        let nv = (columns + 1) * (rows + 1), n = 2 * nv
        let span = SIMD2(Double(columns), Double(rows))
        func rest(_ i: Int, _ j: Int) -> SIMD2<Double> {
            let t = SIMD2(Double(i), Double(j)) / span
            return origin + t * size
        }
        let prior = (0..<nv).map { k in project(toB, rest(k % (columns + 1), k / (columns + 1))) }
        guard !matches.isEmpty else { return prior }

        // Each match's cell and bilinear weights.
        let cells: [[(Int, Double)]] = matches.map { m in
            let g = (m.a - origin) / size * span
            let ci = min(max(Int(g.x), 0), columns - 1), cj = min(max(Int(g.y), 0), rows - 1)
            let fx = g.x - Double(ci), fy = g.y - Double(cj)
            let k00 = cj * (columns + 1) + ci, k10 = k00 + 1, k01 = k00 + columns + 1, k11 = k01 + 1
            return [(k00, (1 - fx) * (1 - fy)), (k10, fx * (1 - fy)), (k01, (1 - fx) * fy), (k11, fx * fy)]
        }
        // Similarity: each corner of each cell keeps its place relative to
        // the other two, up to one rotation and scale per triangle.
        let alpha = 2.5 * max(1, Double(matches.count) / Double(columns * rows * 4))
        let beta = 0.02 * alpha
        var weights = matches.map(\.weight)
        var x = [Double](repeating: 0, count: n)
        for k in 0..<nv { x[2 * k] = prior[k].x; x[2 * k + 1] = prior[k].y }

        // Iteratively reweighted: matches the warp can't agree with lose
        // their pull, so a few wrong ones can't bend a region.
        for round in 0..<3 {
            var normal = SparseNormal(size: n)
            for (m, (cell, w)) in zip(matches, zip(cells, weights)) {
                for axis in 0..<2 {
                    normal.addRow(cell.map { (2 * $0.0 + axis, $0.1) }, rhs: axis == 0 ? m.b.x : m.b.y, weight: w)
                }
            }
            for j in 0..<rows {
                for i in 0..<columns {
                    let k00 = j * (columns + 1) + i, k10 = k00 + 1, k01 = k00 + columns + 1, k11 = k01 + 1
                    for (v1, v2, v3) in [(k00, k10, k01), (k10, k11, k00), (k11, k01, k10), (k01, k00, k11)] {
                        let p1 = rest(v1 % (columns + 1), v1 / (columns + 1))
                        let p2 = rest(v2 % (columns + 1), v2 / (columns + 1))
                        let p3 = rest(v3 % (columns + 1), v3 / (columns + 1))
                        let d = p3 - p2, e = p1 - p2, dd = simd_length_squared(d)
                        let u = simd_dot(e, d) / dd, v = simd_dot(e, SIMD2(-d.y, d.x)) / dd
                        // x: V1x − V2x − u(V3x − V2x) + v(V3y − V2y) = 0
                        normal.addRow([(2 * v1, 1), (2 * v2, -1 + u), (2 * v3, -u), (2 * v3 + 1, v), (2 * v2 + 1, -v)], rhs: 0, weight: alpha)
                        // y: V1y − V2y − u(V3y − V2y) − v(V3x − V2x) = 0
                        normal.addRow([(2 * v1 + 1, 1), (2 * v2 + 1, -1 + u), (2 * v3 + 1, -u), (2 * v3, -v), (2 * v2, v)], rhs: 0, weight: alpha)
                    }
                }
            }
            // Prior: stay with the global placement unless something says otherwise.
            for k in 0..<nv {
                normal.addRow([(2 * k, 1)], rhs: prior[k].x, weight: beta)
                normal.addRow([(2 * k + 1, 1)], rhs: prior[k].y, weight: beta)
            }
            normal.conjugateGradient(&x, iterations: round == 0 ? 400 : 200)
            guard round < 2 else { break }
            // About two detail pixels of the second photo.
            let tolerance = 2.0 / 320
            for (index, (m, cell)) in zip(matches, cells).enumerated() {
                var fit = SIMD2(0.0, 0.0)
                for (k, w) in cell { fit += SIMD2(x[2 * k], x[2 * k + 1]) * w }
                let r = simd_length(fit - m.b) / tolerance
                weights[index] = m.weight / (1 + r * r)
            }
        }
        return (0..<nv).map { SIMD2(x[2 * $0], x[2 * $0 + 1]) }
    }

    /// Gain and offset per channel taking the first photo's colours around
    /// `pa` to the second's around `qb`, or nil when either side runs out.
    static func colourShift(
        _ a: LiquidPhotoInfo, _ b: LiquidPhotoInfo, at pa: SIMD2<Double>, matchedTo qb: SIMD2<Double>,
        radius: Double, toB: simd_double3x3
    ) -> (SIMD3<Double>, SIMD3<Double>)? {
        // The second photo's units per world unit around here.
        let scale = simd_length(project(toB, pa + SIMD2(radius, 0)) - project(toB, pa)) / radius
        var sa = [SIMD3<Double>](), sb = [SIMD3<Double>]()
        for dy in -3...3 {
            for dx in -3...3 {
                let o = SIMD2(Double(dx), Double(dy)) / 3 * radius
                let p = pa + o, q = qb + o * scale
                guard p.x >= 0, p.x <= 1, p.y >= 0, p.y <= a.height, q.x >= 0, q.x <= 1, q.y >= 0, q.y <= b.height else { continue }
                func rgb(_ img: FlowImage, _ h: Double, _ s: SIMD2<Double>) -> SIMD3<Double> {
                    SIMD3((0..<3).map { Double(img.sampleMirrored($0, Float(s.x), Float(s.y / h))) })
                }
                sa.append(rgb(a.detail, a.height, p))
                sb.append(rgb(b.detail, b.height, q))
            }
        }
        guard sa.count >= 20 else { return nil }
        let n = Double(sa.count)
        let ma = sa.reduce(.zero, +) / n, mb = sb.reduce(.zero, +) / n
        let va = sa.reduce(SIMD3<Double>.zero) { $0 + ($1 - ma) * ($1 - ma) } / n
        let vb = sb.reduce(SIMD3<Double>.zero) { $0 + ($1 - mb) * ($1 - mb) } / n
        let gain = simd_clamp((vb / simd_max(va, SIMD3(repeating: 1e-4))).squareRoot(), SIMD3(repeating: 0.6), SIMD3(repeating: 1.6))
        return (gain, mb - gain * ma)
    }

    static func smoothed(_ f: [Double], _ w: Int, _ h: Int, passes: Int) -> [Double] {
        var f = f
        for _ in 0..<passes {
            let g = f
            for y in 0..<h {
                for x in 0..<w {
                    var s = g[y * w + x] * 2, c = 2.0
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] where x + dx >= 0 && x + dx < w && y + dy >= 0 && y + dy < h {
                        s += g[(y + dy) * w + x + dx]
                        c += 1
                    }
                    f[y * w + x] = s / c
                }
            }
        }
        return f
    }
}

/// The normal equations AᵀA x = Aᵀb of a sparse least-squares system,
/// accumulated one weighted row at a time and solved by conjugate gradient.
struct SparseNormal {
    let size: Int
    private var entries: [[Int: Double]]
    private var rhs: [Double]

    init(size: Int) {
        self.size = size
        entries = Array(repeating: [:], count: size)
        rhs = Array(repeating: 0, count: size)
    }

    mutating func addRow(_ terms: [(Int, Double)], rhs b: Double, weight: Double) {
        for (i, ai) in terms {
            rhs[i] += weight * ai * b
            for (j, aj) in terms {
                entries[i][j, default: 0] += weight * ai * aj
            }
        }
    }

    func conjugateGradient(_ x: inout [Double], iterations: Int) {
        let rows = entries.map { Array($0) }
        func multiply(_ v: [Double]) -> [Double] {
            rows.map { row in row.reduce(0) { $0 + $1.value * v[$1.key] } }
        }
        let diagonal = (0..<size).map { max(entries[$0][$0] ?? 1, 1e-12) }
        let ax = multiply(x)
        var r = (0..<size).map { rhs[$0] - ax[$0] }
        var z = (0..<size).map { r[$0] / diagonal[$0] }
        var p = z
        var rz = zip(r, z).reduce(0) { $0 + $1.0 * $1.1 }
        for _ in 0..<iterations {
            let ap = multiply(p)
            let pap = zip(p, ap).reduce(0) { $0 + $1.0 * $1.1 }
            guard pap > 1e-18 else { break }
            let step = rz / pap
            for i in 0..<size {
                x[i] += step * p[i]
                r[i] -= step * ap[i]
            }
            z = (0..<size).map { r[$0] / diagonal[$0] }
            let next = zip(r, z).reduce(0) { $0 + $1.0 * $1.1 }
            if next < 1e-14 { break }
            p = (0..<size).map { z[$0] + next / rz * p[$0] }
            rz = next
        }
    }
}
