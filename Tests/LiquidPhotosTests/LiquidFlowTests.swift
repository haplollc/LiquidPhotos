import CoreGraphics
import UIKit
import XCTest
import simd
@testable import LiquidPhotos

/// The self-contained maths: the flow solver, the morph's endpoints, and
/// placing one photo inside another.
final class LiquidFlowTests: XCTestCase {
    /// A smooth blob moved by a known amount comes back as that motion.
    func testFlowRecoversAShift() {
        let w = 64, h = 48
        func blob(_ cx: Float, _ cy: Float) -> FlowImage {
            var img = FlowImage(width: w, height: h, channels: 3)
            for y in 0..<h {
                for x in 0..<w {
                    let dx = Float(x) - cx, dy = Float(y) - cy
                    let v = exp(-(dx * dx + dy * dy) / (2 * 7 * 7))
                    img.planes[0][y * w + x] = v
                    img.planes[1][y * w + x] = 0.5 * v
                    img.planes[2][y * w + x] = 1 - v
                }
            }
            return img.normalized()
        }
        let flow = LiquidFlowSolver.flow(from: blob(28, 24), to: blob(33, 21))
        let centre = 24 * w + 28
        XCTAssertEqual(flow.u[centre], 5, accuracy: 1.2)
        XCTAssertEqual(flow.v[centre], -3, accuracy: 1.2)
    }

    /// A morph starts exactly on the first photo's view and lands exactly
    /// on the second's, and a close-up's view is a small quad in the world.
    func testMorphLandsExactlyOnEachView() {
        // The second photo is the region x 0.3...0.7, y 0.2...0.5 of a 4:3 first photo, at 4:3 too.
        let heightA = 0.75, heightB = 0.75
        let toB = simd_double3x3(rows: [SIMD3(2.5, 0, -0.75), SIMD3(0, 2.5, -0.5), SIMD3(0, 0, 1)])
        let morph = LiquidMorph(heightA: heightA, heightB: heightB, toB: toB, related: true)
        let corners = [SIMD2(0.0, 0.0), SIMD2(1.0, 0.0), SIMD2(1.0, 1.0), SIMD2(0.0, 1.0)]
        let start = morph.frame(at: 0, maxHeight: 2), end = morph.frame(at: 1, maxHeight: 2)
        let expectedA = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 0.75), SIMD2(0, 0.75)]
        let expectedB = [SIMD2(0.3, 0.2), SIMD2(0.7, 0.2), SIMD2(0.7, 0.5), SIMD2(0.3, 0.5)]
        for i in 0..<4 {
            let a = project(start.view, corners[i]), b = project(end.view, corners[i])
            XCTAssertEqual(a.x, expectedA[i].x, accuracy: 1e-9); XCTAssertEqual(a.y, expectedA[i].y, accuracy: 1e-9)
            XCTAssertEqual(b.x, expectedB[i].x, accuracy: 1e-9); XCTAssertEqual(b.y, expectedB[i].y, accuracy: 1e-9)
        }
        XCTAssertEqual(start.blend, 0)
        XCTAssertEqual(end.blend, 1)
        // Halfway, the camera's width is the geometric mean: a steady approach.
        let middle = LiquidView.similarity(of: corners.map { project(morph.frame(at: 0.5, maxHeight: 2).view, $0) })
        XCTAssertEqual(middle.width, (1.0 * 0.4).squareRoot(), accuracy: 1e-6)
    }

    /// Vision finds a real close-up inside the wide shot, in the right place,
    /// and refuses to align two unrelated photos.
    func testAlignmentPlacesACloseUpAndRejectsStrangers() throws {
        guard let folder = ProcessInfo.processInfo.environment["LIQUID_PHOTOS"] else {
            throw XCTSkip("set TEST_RUNNER_LIQUID_PHOTOS to the demo photo folder")
        }
        func load(_ name: String) throws -> CGImage {
            try XCTUnwrap(UIImage(contentsOfFile: folder + "/" + name)?.cgImage)
        }
        let wide = try load("01_cat.jpg")
        let crop = CGRect(x: 0.35, y: 0.15, width: 0.45, height: 0.45)
        let close = try XCTUnwrap(wide.cropping(to: CGRect(
            x: crop.minX * Double(wide.width), y: crop.minY * Double(wide.height),
            width: crop.width * Double(wide.width), height: crop.height * Double(wide.height)
        )))
        let a = try XCTUnwrap(LiquidPreparation.info(for: wide))
        let b = try XCTUnwrap(LiquidPreparation.info(for: close))
        let (toB, related) = LiquidPreparation.alignment(a, b)
        XCTAssertTrue(related, "the close-up wasn't recognised")
        let view = LiquidMorph.band(height: b.height, maxHeight: 100).map { project(toB.inverse, $0) }
        let expected = [
            SIMD2(crop.minX, crop.minY * a.height), SIMD2(crop.maxX, crop.minY * a.height),
            SIMD2(crop.maxX, crop.maxY * a.height), SIMD2(crop.minX, crop.maxY * a.height),
        ]
        for i in 0..<4 {
            XCTAssertEqual(view[i].x, expected[i].x, accuracy: 0.02, "corner \(i)")
            XCTAssertEqual(view[i].y, expected[i].y, accuracy: 0.02, "corner \(i)")
        }
        let stranger = try XCTUnwrap(LiquidPreparation.info(for: try load("02_bullring_city.jpg")))
        XCTAssertFalse(LiquidPreparation.alignment(a, stranger).1, "a cat and a bullring were aligned")
    }

    /// A close-up is the same picture, so the mesh should find plenty of
    /// verified matches and need no local motion on top of the camera: the
    /// regions stay the same and only zoom.
    func testCloseUpMeshKeepsRegionsRigid() throws {
        guard let folder = ProcessInfo.processInfo.environment["LIQUID_PHOTOS"] else {
            throw XCTSkip("set TEST_RUNNER_LIQUID_PHOTOS to the demo photo folder")
        }
        let wide = try XCTUnwrap(UIImage(contentsOfFile: folder + "/01_cat.jpg")?.cgImage)
        let close = try XCTUnwrap(wide.cropping(to: CGRect(x: 0.35 * Double(wide.width), y: 0.15 * Double(wide.height),
                                                           width: 0.45 * Double(wide.width), height: 0.45 * Double(wide.height))))
        let a = try XCTUnwrap(LiquidPreparation.info(for: wide)), b = try XCTUnwrap(LiquidPreparation.info(for: close))
        let started = Date()
        let (morph, mesh) = LiquidPreparation.morph(a, b)
        print("[liquid-mesh] related \(morph.related), \(mesh.matchCount) matches, \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        XCTAssertTrue(morph.related)
        XCTAssertGreaterThan(mesh.matchCount, 60)
        let confident = mesh.vertices.filter { $0.gain.w > 0.5 }
        XCTAssertFalse(confident.isEmpty)
        let moves = confident.map { simd_length($0.worldB - $0.worldA) }.sorted()
        let median = moves[moves.count / 2], p90 = moves[moves.count * 9 / 10]
        print("[liquid-mesh] local motion over the camera: median \(median), p90 \(p90), max \(moves.last!)")
        XCTAssertLessThan(median, 0.004, "matched regions should only ride the camera")
        XCTAssertLessThan(p90, 0.01, "matched regions should only ride the camera")
    }
}
