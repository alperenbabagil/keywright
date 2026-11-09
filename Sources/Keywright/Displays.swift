// Live display arrangement in CoreGraphics global points.
import AppKit
import CoreGraphics
import KeywrightCore

struct DisplayDesc {
    let id: CGDirectDisplayID
    let bounds: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let scale: Double
    let isMain: Bool
    let name: String
}

enum Displays {
    static func all() -> [DisplayDesc] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let names = screenNames()
        return ids.map { id in
            let b = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let pw = mode?.pixelWidth ?? Int(b.width), ph = mode?.pixelHeight ?? Int(b.height)
            return DisplayDesc(id: id, bounds: b, pixelWidth: pw, pixelHeight: ph,
                               scale: b.width > 0 ? Double(pw) / b.width : 1, isMain: CGDisplayIsMain(id) != 0,
                               name: names[id].flatMap { $0.isEmpty ? nil : $0 } ?? "Display \(id)")
        }
    }

    private static func screenNames() -> [CGDirectDisplayID: String] {
        let read = {
            Dictionary(NSScreen.screens.compactMap { s -> (CGDirectDisplayID, String)? in
                guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                return (n.uint32Value, s.localizedName)
            }, uniquingKeysWith: { a, _ in a })
        }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }

    static func under(_ p: CGPoint) -> DisplayDesc? {
        all().first { p.x >= $0.bounds.minX && p.x < $0.bounds.maxX && p.y >= $0.bounds.minY && p.y < $0.bounds.maxY }
    }

    static func find(_ id: Int?) throws -> DisplayDesc {
        let list = all()
        if let id {
            guard let d = list.first(where: { UInt32(exactly: id) == $0.id }) else {
                throw ToolError("no display with id \(id) (have \(list.map { Int($0.id) }))")
            }
            return d
        }
        return list.first(where: \.isMain) ?? list[0]
    }

    static func json(_ d: DisplayDesc, neighbours: [Neighbour]) -> [String: Any] {
        [
            "id": Int(d.id), "name": d.name, "bounds": d.bounds, "pixelWidth": d.pixelWidth,
            "pixelHeight": d.pixelHeight, "scale": d.scale, "isMain": d.isMain,
            "neighbours": neighbours.map { ["edge": $0.edge.rawValue, "displayId": Int($0.displayID), "from": $0.from, "to": $0.to] },
        ]
    }

    static func allJSON() -> [[String: Any]] {
        let list = all()
        let n = neighbours(of: list.map { ($0.id, $0.bounds) })
        return list.map { json($0, neighbours: n[$0.id] ?? []) }
    }

    static func cursorJSON() -> [String: Any] {
        let p = Driver.shared.cursor
        var out: [String: Any] = ["x": p.x, "y": p.y, "hidden": cursorHidden()]
        if let d = under(p) { out["displayId"] = Int(d.id); out["displayName"] = d.name }
        return out
    }
}
