import XCTest

/// A small display left of a taller one, tops at different heights: the arrangement where
/// the left edge of the big display is a wall above and below the small one.
final class EdgeCrossingTests: XCTestCase {
    private let big = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let small = CGRect(x: -1512, y: 400, width: 1512, height: 982)
    private var displays: [CGRect] { [big, small] }

    func testWallAboveTheSmallDisplayLandsOnItsTopEdge() {
        let target = EdgeCrossing.target(from: CGPoint(x: 0, y: 100), delta: CGVector(dx: -3, dy: 0), displays: displays)
        XCTAssertEqual(target, CGPoint(x: -1, y: 400))
    }

    func testWallBelowTheSmallDisplayLandsOnItsBottomEdge() {
        let target = EdgeCrossing.target(from: CGPoint(x: 0, y: 1430), delta: CGVector(dx: -3, dy: 0), displays: displays)
        XCTAssertEqual(target, CGPoint(x: -1, y: 1381))
    }

    /// Where the displays touch, macOS crosses by itself.
    func testSharedEdgeIsLeftToMacOS() {
        XCTAssertNil(EdgeCrossing.target(from: CGPoint(x: 0, y: 700), delta: CGVector(dx: -3, dy: 0), displays: displays))
    }

    func testNoPushNoWarp() {
        XCTAssertNil(EdgeCrossing.target(from: CGPoint(x: 0, y: 100), delta: CGVector(dx: 0, dy: 3), displays: displays))
        XCTAssertNil(EdgeCrossing.target(from: CGPoint(x: 0, y: 100), delta: CGVector(dx: 3, dy: 0), displays: displays))
    }

    /// The outer edges have no neighbour: they stay walls.
    func testOuterEdgeStaysAWall() {
        XCTAssertNil(EdgeCrossing.target(from: CGPoint(x: 2559, y: 100), delta: CGVector(dx: 3, dy: 0), displays: displays))
        XCTAssertNil(EdgeCrossing.target(from: CGPoint(x: 1000, y: 0), delta: CGVector(dx: 0, dy: -3), displays: displays))
    }

    /// The other way: from the small display's right edge nothing is ever a wall.
    func testSmallToBigIsLeftToMacOS() {
        XCTAssertNil(EdgeCrossing.target(from: CGPoint(x: -1, y: 500), delta: CGVector(dx: 3, dy: 0), displays: displays))
    }

    /// A narrow display above a wide one, off to the left.
    func testVerticalWall() {
        let above = CGRect(x: 200, y: -900, width: 1600, height: 900)
        let target = EdgeCrossing.target(from: CGPoint(x: 2400, y: 0), delta: CGVector(dx: 0, dy: -2), displays: [big, above])
        XCTAssertEqual(target, CGPoint(x: 1799, y: -1))
    }

    /// Scaled displays stop the pointer a fraction short of the edge.
    func testFractionalEdgePosition() {
        let target = EdgeCrossing.target(from: CGPoint(x: 0.5, y: 100), delta: CGVector(dx: -1, dy: 0), displays: displays)
        XCTAssertEqual(target, CGPoint(x: -1, y: 400))
    }
}
