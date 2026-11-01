import XCTest
@testable import LiquidPhotos

/// The self-contained maths: the flow solver and the camera's endpoints.
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

    /// A transition starts exactly on the first photo at rest and lands
    /// exactly on the second, whatever their shapes and subjects.
    func testCameraLandsOnEachPhotoAtRest() {
        let a = LiquidFrame(aspect: 4 / 3, subject: CGRect(x: 0.1, y: 0.4, width: 0.5, height: 0.5))
        let b = LiquidFrame(aspect: 2 / 3, subject: CGRect(x: 0.5, y: 0.1, width: 0.3, height: 0.3))
        let pair = LiquidPairGeometry(a, b)
        let motion = LiquidMotion()
        let start = pair.camera(at: 0, startZoom: 1, maxHeight: 1.4, motion: motion)
        let end = pair.camera(at: 1, startZoom: 1, maxHeight: 1.4, motion: motion)
        for p in [SIMD2(-0.5, -0.3), SIMD2(0.2, 0.1), SIMD2(0.45, 0.35)] {
            let qa = start.source(of: p, anchor: a.anchor, size: pair.sizeA)
            XCTAssertEqual(qa.x, p.x, accuracy: 1e-9)
            XCTAssertEqual(qa.y, p.y, accuracy: 1e-9)
            let qb = end.source(of: p, anchor: b.anchor, size: pair.sizeB)
            XCTAssertEqual(qb.x, p.x, accuracy: 1e-9)
            XCTAssertEqual(qb.y, p.y, accuracy: 1e-9)
        }
        XCTAssertEqual(start.halfHeight, 0.375, accuracy: 1e-9)
        XCTAssertEqual(end.halfHeight, 0.7, accuracy: 1e-9)
        XCTAssertEqual(start.morph, 0)
        XCTAssertEqual(end.morph, 1)
        XCTAssertEqual(start.blur, 0, accuracy: 1e-9)
    }
}
