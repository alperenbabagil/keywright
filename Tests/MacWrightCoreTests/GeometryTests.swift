import CoreGraphics
import XCTest
@testable import MacWrightCore

final class GeometryTests: XCTestCase {
    // Main display plus a smaller one to its right, aligned 300pt lower:
    //   main  (0,0)-(1512,982)
    //   right (1512,300)-(3432,1380)
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let right = CGRect(x: 1512, y: 300, width: 1920, height: 1080)
    lazy var layout = RectLayout([main, right])

    // MARK: clampedStep

    func testFreeMove() {
        let p = clampedStep(CGPoint(x: 100, y: 100), 10, -5, in: RectLayout([main]))
        XCTAssertEqual(p, CGPoint(x: 110, y: 95))
    }

    func testStopsFlushAtEdge() {
        // Bounds are half-open: the last x on the main display is 1511.
        let p = clampedStep(CGPoint(x: 1500, y: 100), 50, 0, in: RectLayout([main]))
        XCTAssertEqual(p, CGPoint(x: 1511, y: 100))
        let q = clampedStep(CGPoint(x: 5, y: 5), -20, -20, in: RectLayout([main]))
        XCTAssertEqual(q, CGPoint(x: 0, y: 0))
    }

    func testSlidesAlongEdge() {
        // Pushing diagonally into the left edge keeps the vertical part.
        let p = clampedStep(CGPoint(x: 2, y: 500), -10, 30, in: RectLayout([main]))
        XCTAssertEqual(p, CGPoint(x: 0, y: 530))
    }

    func testCrossesIntoNeighbour() {
        let p = clampedStep(CGPoint(x: 1505, y: 500), 20, 0, in: layout)
        XCTAssertEqual(p, CGPoint(x: 1525, y: 500))
    }

    func testBlockedWhereNeighbourDoesNotReach() {
        // At y = 100 the right display does not exist (it starts at y = 300).
        let p = clampedStep(CGPoint(x: 1505, y: 100), 20, 0, in: layout)
        XCTAssertEqual(p, CGPoint(x: 1511, y: 100))
    }

    func testCornerGapSlides() {
        // From the right display's top-left area going up-left the full step lands on main: taken as is.
        let p = clampedStep(CGPoint(x: 1520, y: 310), -20, -20, in: layout)
        XCTAssertEqual(p, CGPoint(x: 1500, y: 290))
        // Going straight up out of the right display at x=2000 is blocked at its top edge.
        let q = clampedStep(CGPoint(x: 2000, y: 305), 0, -30, in: layout)
        XCTAssertEqual(q, CGPoint(x: 2000, y: 300))
    }

    func testDisplayLeftOfMainHasNegativeX() {
        let left = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let l = RectLayout([main, left])
        let p = clampedStep(CGPoint(x: 3, y: 50), -10, 0, in: l)
        XCTAssertEqual(p, CGPoint(x: -7, y: 50))
        XCTAssertTrue(l.onScreen(CGPoint(x: -1920, y: -200)))
        XCTAssertFalse(l.onScreen(CGPoint(x: -1921, y: 0)))
    }

    // MARK: motion planning

    func testIntegerSplitSumsExactly() {
        for (total, n) in [(200.0, 20), (37.0, 7), (-55.0, 6), (3.0, 10), (0.0, 4)] {
            let parts = integerSplit(total, steps: n)
            XCTAssertEqual(parts.count, n)
            XCTAssertEqual(parts.reduce(0, +), total)
            XCTAssertTrue(parts.allSatisfy { $0 == $0.rounded() })
        }
    }

    func testGlideReachesTargetSmoothly() {
        let d = glideDeltas(dx: 300, dy: -120, steps: 30)
        XCTAssertEqual(d.count, 30)
        XCTAssertEqual(d.reduce(0) { $0 + $1.dx }, 300)
        XCTAssertEqual(d.reduce(0) { $0 + $1.dy }, -120)
        // Ease in/out: the middle steps are bigger than the first and last.
        XCTAssertLessThan(abs(d.first!.dx), abs(d[15].dx))
        XCTAssertLessThan(abs(d.last!.dx), abs(d[15].dx))
    }

    func testPushRightEdge() {
        let plan = planPushEdge(bounds: main, edge: .right, along: 0.5, distance: 200, steps: 20)
        XCTAssertEqual(plan.edgePoint, CGPoint(x: 1511, y: 491))
        XCTAssertEqual(plan.start, CGPoint(x: 1471, y: 491))
        XCTAssertEqual(plan.approach.reduce(0) { $0 + $1.dx }, 40)
        XCTAssertTrue(plan.approach.allSatisfy { $0.dy == 0 && $0.dx >= 0 })
        XCTAssertEqual(plan.push.count, 20)
        XCTAssertEqual(plan.push.reduce(0) { $0 + $1.dx }, 200)
        XCTAssertTrue(plan.push.allSatisfy { $0.dy == 0 && $0.dx == 10 })
    }

    func testPushOtherEdges() {
        let left = planPushEdge(bounds: right, edge: .left, along: 0, distance: 50, steps: 5)
        XCTAssertEqual(left.edgePoint, CGPoint(x: 1512, y: 300))
        XCTAssertEqual(left.push.reduce(0) { $0 + $1.dx }, -50)

        let top = planPushEdge(bounds: main, edge: .top, along: 1, distance: 30, steps: 3)
        XCTAssertEqual(top.edgePoint, CGPoint(x: 1511, y: 0))
        XCTAssertEqual(top.start.y, 40)
        XCTAssertEqual(top.push.reduce(0) { $0 + $1.dy }, -30)

        let bottom = planPushEdge(bounds: main, edge: .bottom, along: 0.25, distance: 100, steps: 4)
        XCTAssertEqual(bottom.edgePoint, CGPoint(x: 378, y: 981))
        XCTAssertEqual(bottom.push, Array(repeating: CGVector(dx: 0, dy: 25), count: 4))
    }

    func testPushPlanFollowsClampToTheEdge() {
        // Running the plan through the clamp model ends flush against the edge, then stays there
        // (no neighbour on main's top edge), or crosses where a neighbour exists.
        var p = planPushEdge(bounds: main, edge: .top, along: 0.5, distance: 100, steps: 10).start
        let plan = planPushEdge(bounds: main, edge: .top, along: 0.5, distance: 100, steps: 10)
        for d in plan.approach { p = clampedStep(p, d.dx, d.dy, in: layout) }
        XCTAssertEqual(p, plan.edgePoint)
        for d in plan.push { p = clampedStep(p, d.dx, d.dy, in: layout) }
        XCTAssertEqual(p, plan.edgePoint)

        let cross = planPushEdge(bounds: main, edge: .right, along: 0.8, distance: 100, steps: 10)
        p = cross.start
        for d in cross.approach + cross.push { p = clampedStep(p, d.dx, d.dy, in: layout) }
        XCTAssertEqual(p.x, cross.edgePoint.x + 100)
    }

    func testAlongIsClamped() {
        let plan = planPushEdge(bounds: main, edge: .left, along: 7, distance: 10, steps: 1)
        XCTAssertEqual(plan.edgePoint, CGPoint(x: 0, y: 981))
    }

    // MARK: neighbours

    func testNeighbours() {
        let below = CGRect(x: 200, y: 982, width: 800, height: 600)
        let corner = CGRect(x: -500, y: -400, width: 500, height: 400)  // touches main only at a corner
        let n = neighbours(of: [(1, main), (2, right), (3, below), (4, corner)])
        XCTAssertEqual(n[1], [Neighbour(edge: .right, displayID: 2, from: 300, to: 982),
                              Neighbour(edge: .bottom, displayID: 3, from: 200, to: 1000)])
        XCTAssertEqual(n[2], [Neighbour(edge: .left, displayID: 1, from: 300, to: 982)])
        XCTAssertEqual(n[3], [Neighbour(edge: .top, displayID: 1, from: 200, to: 1000)])
        XCTAssertEqual(n[4], [])
    }
}
