// Pure geometry for the physical-mouse model. Coordinates are CoreGraphics global points:
// origin at the top-left of the main display, y down, negative left of / above it.
import CoreGraphics
import Foundation

/// Anything that can say whether a global point lies on a display. The live implementation asks
/// CoreGraphics; tests use `RectLayout` with fake display arrangements.
public protocol ScreenLayout {
    func onScreen(_ p: CGPoint) -> Bool
}

/// A layout made of display rectangles. Bounds are half-open (a point on maxX is off that display),
/// like the real cursor range and `CGGetDisplaysWithPoint`.
public struct RectLayout: ScreenLayout {
    public var rects: [CGRect]
    public init(_ rects: [CGRect]) { self.rects = rects }
    public func onScreen(_ p: CGPoint) -> Bool {
        rects.contains { p.x >= $0.minX && p.x < $0.maxX && p.y >= $0.minY && p.y < $0.maxY }
    }
}

/// Moves like a physical mouse: the location never leaves the displays, sliding along an edge.
public func clampedStep(_ from: CGPoint, _ dx: Double, _ dy: Double, in layout: ScreenLayout) -> CGPoint {
    let full = CGPoint(x: from.x + dx, y: from.y + dy)
    if layout.onScreen(full) { return full }
    // Blocked: move flush against the edge on each axis, then slide along it.
    var p = from
    let sx = dx == 0 ? 0.0 : (dx > 0 ? 1.0 : -1.0), sy = dy == 0 ? 0.0 : (dy > 0 ? 1.0 : -1.0)
    var rx = abs(dx), ry = abs(dy)
    while rx >= 1 && layout.onScreen(CGPoint(x: p.x + sx, y: p.y)) { p.x += sx; rx -= 1 }
    while ry >= 1 && layout.onScreen(CGPoint(x: p.x, y: p.y + sy)) { p.y += sy; ry -= 1 }
    return p
}

// MARK: - Display arrangement

public enum Edge: String, CaseIterable, Codable, Sendable {
    case left, right, top, bottom
}

/// One display that touches another along an edge.
public struct Neighbour: Equatable, Sendable {
    public var edge: Edge
    public var displayID: UInt32
    /// The shared stretch of the edge, in global points (y range for left/right, x range for top/bottom).
    public var from: Double
    public var to: Double
}

/// For each display, the displays touching each of its edges (corner-only contact does not count).
public func neighbours(of displays: [(id: UInt32, bounds: CGRect)]) -> [UInt32: [Neighbour]] {
    var result: [UInt32: [Neighbour]] = [:]
    func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.5 }
    for a in displays {
        var list: [Neighbour] = []
        for b in displays where b.id != a.id {
            let yLo = max(a.bounds.minY, b.bounds.minY), yHi = min(a.bounds.maxY, b.bounds.maxY)
            let xLo = max(a.bounds.minX, b.bounds.minX), xHi = min(a.bounds.maxX, b.bounds.maxX)
            if yHi > yLo {
                if close(a.bounds.maxX, b.bounds.minX) { list.append(Neighbour(edge: .right, displayID: b.id, from: yLo, to: yHi)) }
                if close(a.bounds.minX, b.bounds.maxX) { list.append(Neighbour(edge: .left, displayID: b.id, from: yLo, to: yHi)) }
            }
            if xHi > xLo {
                if close(a.bounds.maxY, b.bounds.minY) { list.append(Neighbour(edge: .bottom, displayID: b.id, from: xLo, to: xHi)) }
                if close(a.bounds.minY, b.bounds.maxY) { list.append(Neighbour(edge: .top, displayID: b.id, from: xLo, to: xHi)) }
            }
        }
        result[a.id] = list
    }
    return result
}

// MARK: - Motion planning

/// Splits [total] into [steps] integer parts that add up to it exactly (rounded), spread evenly.
public func integerSplit(_ total: Double, steps: Int) -> [Double] {
    let n = max(1, steps)
    var out: [Double] = []
    var done = 0.0
    for i in 1...n {
        let target = (total * Double(i) / Double(n)).rounded()
        out.append(target - done)
        done = target
    }
    return out
}

/// Integer deltas for a smooth (ease-in-out) glide by (dx, dy) over [steps] events.
public func glideDeltas(dx: Double, dy: Double, steps: Int) -> [CGVector] {
    let n = max(1, steps)
    var out: [CGVector] = []
    var px = 0.0, py = 0.0
    for i in 1...n {
        let t = Double(i) / Double(n)
        let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        let x = (dx * e).rounded(), y = (dy * e).rounded()
        out.append(CGVector(dx: x - px, dy: y - py))
        px = x; py = y
    }
    return out
}

/// How push_edge drives the cursor: start inside the display, glide to the edge with posted
/// deltas, dwell there, then keep pushing outward by `distance` points.
public struct PushPlan: Equatable {
    public var start: CGPoint
    public var edgePoint: CGPoint
    public var approach: [CGVector]
    public var push: [CGVector]
}

/// Plans a push against [edge] of a display with [bounds]. [along] picks the spot on the edge
/// (0 = top/left end, 1 = bottom/right end); [inset] is how far inside the edge the approach starts.
public func planPushEdge(bounds: CGRect, edge: Edge, along: Double, distance: Double, steps: Int,
                         inset: Double = 40) -> PushPlan {
    let a = min(1, max(0, along))
    // Last addressable point on each axis (bounds are half-open).
    let lastX = bounds.maxX - 1, lastY = bounds.maxY - 1
    let ax = (bounds.minX + a * (lastX - bounds.minX)).rounded()
    let ay = (bounds.minY + a * (lastY - bounds.minY)).rounded()
    let inX = min(inset, max(0, bounds.width / 2 - 1)), inY = min(inset, max(0, bounds.height / 2 - 1))
    let edgePoint: CGPoint, start: CGPoint, out: CGVector
    switch edge {
    case .left:   edgePoint = CGPoint(x: bounds.minX, y: ay); start = CGPoint(x: bounds.minX + inX, y: ay); out = CGVector(dx: -1, dy: 0)
    case .right:  edgePoint = CGPoint(x: lastX, y: ay);       start = CGPoint(x: lastX - inX, y: ay);       out = CGVector(dx: 1, dy: 0)
    case .top:    edgePoint = CGPoint(x: ax, y: bounds.minY); start = CGPoint(x: ax, y: bounds.minY + inY); out = CGVector(dx: 0, dy: -1)
    case .bottom: edgePoint = CGPoint(x: ax, y: lastY);       start = CGPoint(x: ax, y: lastY - inY);       out = CGVector(dx: 0, dy: 1)
    }
    let gap = Double(abs(edgePoint.x - start.x) + abs(edgePoint.y - start.y))
    let approach = integerSplit(gap, steps: max(1, Int((gap / 8).rounded(.up))))
        .map { CGVector(dx: out.dx * $0, dy: out.dy * $0) }
    let push = integerSplit(max(0, distance), steps: max(1, steps))
        .map { CGVector(dx: out.dx * $0, dy: out.dy * $0) }
    return PushPlan(start: start, edgePoint: edgePoint, approach: approach, push: push)
}
