// Event taps that show what was actually delivered: record_events (full field dump to a file),
// watch_events and the per-tool `watch` option (compact), and the self-tests.
//
// Every event MacWright posts carries kCGEventSourceUserData = Marker.synthetic, so a recording
// tells synthetic input from the user's, and a self-test can swallow its own events (an active
// tap at the head of the HID stream drops only marked events) without touching any app.
//
// Completion is decided by a fence, never by a quiet period: after the action MacWright posts one
// more marked event and waits until every tap has seen it. A tap sees events in posting order, so
// the fence proves the action's events got there too, however long delivery took. (The old rule,
// "done once no new event arrived for 120 ms", could not tell a quiet stream from a stalled one:
// when delivery to the tap was held up it declared the call finished, tore the taps down and
// reported nothing although the events were delivered.)
//
// The tap callback stays free of AppKit: NSEvent(cgEvent:) / -characters call into the Text
// Services Manager, which must run on the main thread (it asserts and crashes the app when a human
// key event is converted on the tap thread). Events are copied and converted on the main thread
// when results are read.
import AppKit
import CoreGraphics
import Foundation
import MacWrightCore

typealias Marker = OwnMarker

struct Recorded {
    let t: Double              // ms since the recording started
    let tap: String            // "hid" or "session"
    let type: UInt32
    let flags: UInt64
    let location: CGPoint
    let userData: Int64
    let ints: [Int: Int64]     // every non-zero integer field 0-255
    let doubles: [Int: Double] // every non-zero double field 0-255 that differs from its integer view
    var ns: [String: Any]?     // NSEvent(cgEvent:) view, when one can be built (filled on the main thread)
    var cg: CGEvent?           // copy kept until `ns` is filled

    var synthetic: Bool { userData == Marker.synthetic }
    var bookkeeping: Bool { Marker.isBookkeeping(userData) }
    var keyCode: Int64 { ints[9] ?? 0 }

    /// Compact form for tool results.
    var compact: [String: Any] {
        var o: [String: Any] = ["t": (t * 10).rounded() / 10, "tap": tap, "type": Int(type), "name": EventNames.name(type)]
        if synthetic { o["synthetic"] = true }
        if flags & ~EventFlag.nonCoalesced != 0 || [10, 11, 12].contains(type) {
            o["flags"] = String(format: "0x%llx", flags)
            let names = EventFlag.names(flags)
            if !names.isEmpty { o["mods"] = names }
        }
        switch type {
        case 10, 11, 12:
            o["keyCode"] = Int(keyCode)
            if let c = ns?["characters"] { o["chars"] = c }
        case 1...7, 25...27:
            o["at"] = location
            if let dx = ints[4], dx != 0 { o["dx"] = dx }
            if let dy = ints[5], dy != 0 { o["dy"] = dy }
            if let cs = ints[1], cs != 0, ![5, 6, 7, 27].contains(type) { o["clickState"] = cs }
        case 22:
            o["at"] = location
            o["deltaY"] = doubles[96] ?? Double(ints[96] ?? 0)
            o["deltaX"] = doubles[97] ?? Double(ints[97] ?? 0)
            if let ph = ints[99], ph != 0 { o["phase"] = ph }
        default:
            o["at"] = location
        }
        if let ns, type == 29 || type > 27 { o["ns"] = ns }
        return o
    }

    var full: [String: Any] {
        var o = compact
        o["flagsRaw"] = String(format: "0x%llx", flags)
        o["ints"] = Dictionary(uniqueKeysWithValues: ints.map { (String($0.key), $0.value) })
        o["doubles"] = Dictionary(uniqueKeysWithValues: doubles.map { (String($0.key), $0.value) })
        if let ns { o["ns"] = ns }
        return o
    }
}

enum EventNames {
    static func name(_ t: UInt32) -> String {
        [1: "leftMouseDown", 2: "leftMouseUp", 3: "rightMouseDown", 4: "rightMouseUp", 5: "mouseMoved",
         6: "leftMouseDragged", 7: "rightMouseDragged", 10: "keyDown", 11: "keyUp", 12: "flagsChanged",
         14: "systemDefined", 22: "scrollWheel", 23: "tabletPointer", 24: "tabletProximity",
         25: "otherMouseDown", 26: "otherMouseUp", 27: "otherMouseDragged", 29: "gesture",
         0xFFFF_FFFE: "tapDisabledByTimeout", 0xFFFF_FFFF: "tapDisabledByUserInput"][t] ?? "type\(t)"
    }

    static func number(_ name: String) -> UInt32? {
        if let n = UInt32(name) { return n }
        for t in UInt32(0)..<40 where self.name(t).caseInsensitiveCompare(name) == .orderedSame { return t }
        return nil
    }
}

/// The NSEvent view of a CGEvent. Only reads properties valid for the event's type (AppKit raises
/// on the others). Main thread only: -characters goes through the Text Services Manager.
func nsView(_ e: CGEvent) -> [String: Any]? {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let ev = NSEvent(cgEvent: e) else { return nil }
    let t = ev.type
    var o: [String: Any] = ["type": Int(t.rawValue)]
    switch t {
    case .pressure:
        o["stage"] = ev.stage
        o["pressure"] = Double(ev.pressure)
        o["stageTransition"] = Double(ev.stageTransition)
    case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
        o["pressure"] = Double(ev.pressure)
        o["clickCount"] = ev.clickCount
    case .keyDown, .keyUp:
        o["characters"] = ev.characters ?? ""
        o["charactersIgnoringModifiers"] = ev.charactersIgnoringModifiers ?? ""
        o["modifierFlags"] = String(format: "0x%lx", ev.modifierFlags.rawValue)
    case .flagsChanged:
        o["modifierFlags"] = String(format: "0x%lx", ev.modifierFlags.rawValue)
    case .scrollWheel:
        o["phase"] = Int(ev.phase.rawValue)
        o["momentumPhase"] = Int(ev.momentumPhase.rawValue)
    case .magnify, .rotate, .swipe, .smartMagnify:
        o["phase"] = Int(ev.phase.rawValue)
    default:
        break
    }
    return o
}

/// Listen-only taps (HID and/or session) on their own run-loop thread, plus an optional active
/// HID-head tap that swallows MacWright's own marked events.
final class EventRecorder {
    private let lock = NSLock()
    private var events: [Recorded] = []
    private var taps: [(CFMachPort, String)] = []
    private var loop: CFRunLoop?
    private var thread: Thread?
    private let start = DispatchTime.now().uptimeNanoseconds
    let fullFields: Bool
    let maxEvents: Int
    private(set) var dropped = 0
    /// Bookkeeping events (probes, fences) seen, by userData → taps that saw it.
    private var marks: [Int64: Set<String>] = [:]
    /// kCGEventTapDisabledByTimeout / ByUserInput notifications, by tap.
    private var disabled: [String: [String: Int]] = [:]

    private final class Box { weak var rec: EventRecorder?; let tap: String; let swallow: Bool
        init(_ r: EventRecorder, _ t: String, _ s: Bool) { rec = r; tap = t; swallow = s } }
    private var boxes: [Box] = []

    init(fullFields: Bool, maxEvents: Int = 20_000) {
        self.fullFields = fullFields
        self.maxEvents = maxEvents
    }

    static let allEvents: CGEventMask = {
        var m: CGEventMask = 0
        for t in [1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 14, 22, 25, 26, 27, 29] { m |= 1 << CGEventMask(t) }
        return m
    }()

    /// Starts taps at [locations] ("hid", "session"). With [swallowSynthetic], also installs an active
    /// tap at the head of the HID stream that records then drops MacWright's own events.
    func start(_ locations: [String], swallowSynthetic: Bool = false) throws {
        let cb: CGEventTapCallBack = { _, type, event, info in
            let box = Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue()
            guard let rec = box.rec else { return Unmanaged.passUnretained(event) }
            if type.rawValue >= 0xFFFF_FFFE {
                rec.tapDisabled(box.tap, byTimeout: type == .tapDisabledByTimeout)
                return Unmanaged.passUnretained(event)
            }
            rec.record(type, event, tap: box.tap)
            if box.swallow, Marker.isOwn(event.getIntegerValueField(.eventSourceUserData)) { return nil }
            return Unmanaged.passUnretained(event)
        }
        var specs: [(CGEventTapLocation, String, CGEventTapPlacement, CGEventTapOptions, Bool)] = []
        for l in locations {
            switch l {
            case "hid": specs.append((.cghidEventTap, "hid", .tailAppendEventTap, .listenOnly, false))
            case "session": specs.append((.cgSessionEventTap, "session", .tailAppendEventTap, .listenOnly, false))
            default: throw ToolError("tap must be hid or session")
            }
        }
        if swallowSynthetic {
            // Recorded as "hid" — it sees exactly what a HID-level consumer (an app's HID event tap) sees.
            specs.removeAll { $0.1 == "hid" }
            specs.append((.cghidEventTap, "hid", .headInsertEventTap, .defaultTap, true))
        }
        for (loc, name, place, opts, swallow) in specs {
            let box = Box(self, name, swallow)
            boxes.append(box)
            guard let tap = CGEvent.tapCreate(tap: loc, place: place, options: opts, eventsOfInterest: Self.allEvents,
                                              callback: cb, userInfo: Unmanaged.passUnretained(box).toOpaque()) else {
                stop()
                throw ToolError("could not create the \(name) event tap (Accessibility / Input Monitoring?)")
            }
            taps.append((tap, name))
        }
        let ready = DispatchSemaphore(value: 0)
        let taps = self.taps
        let t = Thread { [weak self] in
            self?.loop = CFRunLoopGetCurrent()
            for (tap, _) in taps {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "macwright.recorder"
        t.qualityOfService = .userInteractive
        t.start()
        thread = t
        ready.wait()
    }

    /// The WindowServer disabled a tap (callback too slow, or secure input): count it, log it and
    /// turn the tap back on. Events in between are lost, so results report it.
    private func tapDisabled(_ name: String, byTimeout: Bool) {
        let why = byTimeout ? "timeout" : "userInput"
        lock.withLock { disabled[name, default: [:]][why, default: 0] += 1 }
        Log.write("recorder: \(name) tap disabled by \(why); re-enabled")
        for (tap, n) in taps where n == name { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Runs on the tap thread for every event: plain field reads only (no AppKit).
    private func record(_ type: CGEventType, _ e: CGEvent, tap: String) {
        let ud = e.getIntegerValueField(.eventSourceUserData)
        if Marker.isBookkeeping(ud) {
            lock.withLock { _ = marks[ud, default: []].insert(tap) }
            return
        }
        let t = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        var ints: [Int: Int64] = [:], doubles: [Int: Double] = [:]
        let fields = fullFields ? Array(0..<256) : [1, 4, 5, 9, 41, 42, 88, 96, 97, 99, 110, 143, 147, 148]
        for f in fields {
            guard let field = CGEventField(rawValue: UInt32(f)) else { continue }
            let i = e.getIntegerValueField(field)
            let d = e.getDoubleValueField(field)
            if i != 0 { ints[f] = i }
            if d != 0, d != Double(i) { doubles[f] = d }
        }
        let wantsNS = type.rawValue == 29 || fullFields || [10, 11, 12].contains(type.rawValue)
        let rec = Recorded(t: t, tap: tap, type: type.rawValue, flags: e.flags.rawValue, location: e.location,
                           userData: ud, ints: ints, doubles: doubles, ns: nil, cg: wantsNS ? e.copy() : nil)
        lock.withLock {
            if events.count < maxEvents { events.append(rec) } else { dropped += 1 }
        }
    }

    /// Raw recorded events (no NSEvent view yet).
    var recorded: [Recorded] { lock.withLock { events } }

    /// Tap-disabled notifications seen so far, by tap; empty when none.
    var disabledCounts: [String: [String: Int]] { lock.withLock { disabled } }

    func stop() {
        for (tap, _) in taps { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let loop { CFRunLoopStop(loop) }
        taps.removeAll(); loop = nil
    }

    private func sawMark(_ ud: Int64) -> Set<String> { lock.withLock { marks[ud] ?? [] } }

    /// Posts marked zero-delta probe moves until every tap has seen one (new taps take a moment to
    /// go live). Returns whether all taps came up.
    func waitLive(timeout: Double = 1.5) -> Bool {
        let names = Set(taps.map(\.1))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Driver.shared.postMarker(Marker.probe)
            usleep(40_000)
            if sawMark(Marker.probe).isSuperset(of: names) { return true }
        }
        return false
    }

    private static let fenceLock = NSLock()
    nonisolated(unsafe) private static var fenceSeq = 0

    /// Posts a fence and waits until every tap has seen it: from then on the taps have seen
    /// everything MacWright posted before. `seen` is false when a tap never got it within
    /// [timeout] (another app's tap consumed MacWright's events, or delivery stalled), so the
    /// results may be missing events.
    func fence(timeout: Double = 2.0) -> (seen: Bool, ms: Double, missing: [String]) {
        let seq = Self.fenceLock.withLock { Self.fenceSeq += 1; return Self.fenceSeq }
        let ud = Marker.fence(seq)
        let names = Set(taps.map(\.1))
        let t0 = Date()
        Driver.shared.postMarker(ud)
        var resent = false
        while true {
            let seen = sawMark(ud)
            let ms = (Date().timeIntervalSince(t0) * 1000).rounded()
            if seen.isSuperset(of: names) { return (true, ms, []) }
            if ms >= timeout * 1000 { return (false, ms, names.subtracting(seen).sorted()) }
            // A tap the WindowServer re-enabled after a timeout may have dropped the first one.
            if !resent, ms > 500 { Driver.shared.postMarker(ud); resent = true }
            usleep(3000)
        }
    }

    /// Waits until no new event has arrived for [quietMs] (capped at [maxMs]). Only for
    /// time-boxed recordings; actions use fence().
    func settle(quietMs: Double = 120, maxMs: Double = 1500) {
        let deadline = Date().addingTimeInterval(maxMs / 1000)
        var last = recorded.count, lastChange = Date()
        while Date() < deadline {
            usleep(20_000)
            let n = recorded.count
            if n != last { last = n; lastChange = Date() }
            else if Date().timeIntervalSince(lastChange) * 1000 >= quietMs { return }
        }
    }

    /// Recorded events without the bookkeeping ones, optionally limited to [types], with their
    /// NSEvent view filled in (on the main thread).
    func results(types: Set<UInt32>? = nil) -> [Recorded] {
        Self.withNSView(recorded.filter { types?.contains($0.type) ?? true })
    }

    /// Fills `ns` from the kept CGEvent copies on the main thread (waits at most 2 s for it; on a
    /// busy main thread the events come back without the NSEvent view).
    static func withNSView(_ list: [Recorded]) -> [Recorded] {
        guard list.contains(where: { $0.cg != nil }) else { return list }
        let convert: () -> [Recorded] = {
            list.map { r in
                var r = r
                if let cg = r.cg { r.ns = nsView(cg); r.cg = nil }
                return r
            }
        }
        if Thread.isMainThread { return convert() }
        final class Out: @unchecked Sendable { var v: [Recorded]? }
        let out = Out(), done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { out.v = convert(); done.signal() }
        if done.wait(timeout: .now() + 2) == .timedOut {
            Log.write("recorder: main thread busy; results without the NSEvent view")
            return list.map { var r = $0; r.cg = nil; return r }
        }
        return out.v ?? list
    }
}

/// Folds runs of mouse moves/drags into one entry so watch results stay short.
func summarize(_ events: [Recorded], limit: Int = 120) -> [[String: Any]] {
    var out: [[String: Any]] = []
    var run: (first: Recorded, last: Recorded, count: Int, dx: Int64, dy: Int64)?
    func flush() {
        guard let r = run else { return }
        var o = r.first.compact
        if r.count > 1 {
            o["count"] = r.count
            o["to"] = r.last.location
            o["totalDx"] = r.dx; o["totalDy"] = r.dy
            o.removeValue(forKey: "dx"); o.removeValue(forKey: "dy")
        }
        out.append(o)
        run = nil
    }
    for e in events {
        if [5, 6, 7, 27].contains(e.type) {
            if let r = run, r.first.type == e.type, r.first.tap == e.tap, r.first.synthetic == e.synthetic {
                run = (r.first, e, r.count + 1, r.dx + (e.ints[4] ?? 0), r.dy + (e.ints[5] ?? 0))
            } else {
                flush()
                run = (e, e, 1, e.ints[4] ?? 0, e.ints[5] ?? 0)
            }
        } else {
            flush()
            out.append(e.compact)
        }
    }
    flush()
    if out.count > limit { return Array(out.prefix(limit)) + [["truncated": out.count - limit]] }
    return out
}

enum Recording {
    static func taps(_ s: String) -> [String] {
        switch s { case "hid": return ["hid"]; case "both": return ["hid", "session"]; default: return ["session"] }
    }

    /// Taps requested by a tool call's `watch` (true / "session" / "hid" / "both"); nil = no watch.
    /// `swallow` alone implies the HID tap.
    static func watchTaps(_ a: Args) throws -> [String]? {
        switch a.raw["watch"] {
        case .bool(true)?: return ["session"]
        case .string(let s)?: return taps(s)
        default: return try a.bool("swallow", false) ? [] : nil
        }
    }

    static func typeSet(_ names: [String]?) throws -> Set<UInt32>? {
        guard let names else { return nil }
        return Set(try names.map {
            guard let n = EventNames.number($0) else { throw ToolError("unknown event type '\($0)'") }
            return n
        })
    }

    static var dir: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/MacWright/recordings")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func record(seconds: Double, types: [String]?, taps: [String], path: String?) throws -> [String: Any] {
        let rec = EventRecorder(fullFields: true)
        try rec.start(taps)
        defer { rec.stop() }
        let live = rec.waitLive()
        var left = seconds * 1000
        while left > 0 { try Control.shared.checkPaused(); usleep(100_000); left -= 100 }
        rec.settle(quietMs: 80, maxMs: 400)
        let all = rec.results()
        let url = path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? dir.appendingPathComponent("rec-\(Int(Date().timeIntervalSince1970)).json")
        let data = try JSONSerialization.data(withJSONObject: all.map { jsonSafe($0.full) }, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
        var counts: [String: [String: Int]] = [:]
        for e in all { counts[e.tap, default: [:]][EventNames.name(e.type), default: 0] += 1 }
        let filter = try typeSet(types)
        let picked = all.filter { filter?.contains($0.type) ?? ![5, 6, 7, 27].contains($0.type) }
        return [
            "path": url.path, "tapsLive": live, "events": all.count, "dropped": rec.dropped, "countsByTap": counts,
            "matching": picked.count,
            // Gestures with every field, everything else compact.
            "sample": Array(picked.prefix(150)).map { $0.type == 29 ? $0.full : $0.compact },
        ]
    }

    /// JSONSerialization wants plain types: points become {x, y}.
    static func jsonSafe(_ o: Any) -> Any {
        switch o {
        case let p as CGPoint: return ["x": p.x, "y": p.y]
        case let d as [String: Any]: return d.mapValues(jsonSafe)
        case let a as [Any]: return a.map(jsonSafe)
        default: return o
        }
    }
}
