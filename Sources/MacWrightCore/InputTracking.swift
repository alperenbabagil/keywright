// Pure logic behind MacWright's input bookkeeping: the markers it stamps on its own events, the
// human-input counter, focus-bounce detection, the Notification Center visibility rule and
// status-item selection. No CoreGraphics event or AX calls here, so it is unit-testable.
import Foundation

/// Values MacWright writes into kCGEventSourceUserData on every event it posts. Anything else a tap
/// sees came from the hardware (the human) or from another process.
public enum OwnMarker {
    public static let synthetic: Int64 = 0x4D43_5752        // 'MCWR': the events a tool posts
    public static let probe: Int64 = 0x4D43_5750            // 'MCWP': tap warm-up probes
    /// 'MCWF' << 16 | sequence: a fence posted after an action. Taps see events in posting order,
    /// so once a tap has seen the fence it has seen everything MacWright posted before it.
    public static let fenceTag: Int64 = 0x4D43_5746

    public static func fence(_ seq: Int) -> Int64 { fenceTag << 16 | Int64(seq & 0xFFFF) }
    public static func isFence(_ userData: Int64) -> Bool { userData >> 16 == fenceTag }
    /// Probes and fences: bookkeeping events, hidden from results.
    public static func isBookkeeping(_ userData: Int64) -> Bool { userData == probe || isFence(userData) }
    public static func isOwn(_ userData: Int64) -> Bool { userData == synthetic || isBookkeeping(userData) }
}

/// CGEventType numbers grouped the way a test cares about them.
public enum InputKind {
    public static func of(_ type: UInt32) -> String? {
        switch type {
        case 5: return "move"
        case 6, 7, 27: return "drag"
        case 1, 2, 3, 4, 25, 26: return "click"
        case 10, 11: return "key"
        case 12: return "modifier"
        case 22: return "scroll"
        case 29: return "gesture"       // trackpad touches, pinch, force pressure…
        case 14: return "systemDefined" // media keys, brightness…
        default: return nil
        }
    }
}

/// Counts input that MacWright did not post. The caller serialises access (one lock).
public struct HumanInputLog {
    public private(set) var total = 0
    public private(set) var byKind: [String: Int] = [:]
    /// Wall-clock ms (since 1970) of the latest event, and its kind.
    public private(set) var lastAtMillis: Double?
    public private(set) var lastKind: String?
    /// Events that carried another process's pid (kCGEventSourceUnixProcessID) instead of none.
    public private(set) var byOtherPid: [Int32: Int] = [:]

    private var markTotal = 0
    private var markKinds: [String: Int] = [:]

    public init() {}

    /// Records one event. [sourcePid] is the posting process (0 / our own pid for hardware).
    public mutating func add(kind: String, atMillis: Double, sourcePid: Int32 = 0, ownPid: Int32 = 0) {
        total += 1
        byKind[kind, default: 0] += 1
        lastAtMillis = atMillis
        lastKind = kind
        if sourcePid > 0, sourcePid != ownPid { byOtherPid[sourcePid, default: 0] += 1 }
    }

    /// Counts since the last mark (by kind), then moves the mark to now.
    public mutating func takeSinceMark() -> (count: Int, kinds: [String: Int]) {
        let since = peekSinceMark()
        markTotal = total
        markKinds = byKind
        return since
    }

    /// Counts since the last mark without moving it.
    public func peekSinceMark() -> (count: Int, kinds: [String: Int]) {
        var kinds: [String: Int] = [:]
        for (k, v) in byKind where v - (markKinds[k] ?? 0) > 0 { kinds[k] = v - (markKinds[k] ?? 0) }
        return (total - markTotal, kinds)
    }

    /// Whether human input arrived within [ms] of [nowMillis].
    public func seen(withinMs ms: Double, nowMillis: Double) -> Bool {
        guard let last = lastAtMillis else { return false }
        return nowMillis - last <= ms
    }
}

/// A focus or key/main-window change, as recorded by watch_focus.
public struct FocusChange: Equatable {
    public let seq: Int
    public let t: Double          // ms since the watch started
    public let kind: String       // appActivated, appDeactivated, focusedWindowChanged, mainWindowChanged
    public let pid: Int32
    public let window: String?    // a stable label for the window (id, else title), nil when none

    public init(seq: Int, t: Double, kind: String, pid: Int32, window: String?) {
        self.seq = seq; self.t = t; self.kind = kind; self.pid = pid; self.window = window
    }
}

public enum FocusBounce {
    /// Within one pid and one kind of window change, a window that lost focus/main and got it
    /// back within [withinMs] (A → B → A, or A → none → A). Also flags an app deactivated and
    /// re-activated within [withinMs].
    public static func detect(_ events: [FocusChange], withinMs: Double) -> [[String: Any]] {
        var out: [[String: Any]] = []
        let windowKinds: Set<String> = ["focusedWindowChanged", "mainWindowChanged"]
        var lastByKey: [String: [FocusChange]] = [:]
        for e in events {
            if windowKinds.contains(e.kind) {
                let key = "\(e.pid)/\(e.kind)"
                var hist = lastByKey[key, default: []]
                // Apps often post the same change twice (on the window and on the app): keep the first.
                if let last = hist.last, last.window == e.window { continue }
                hist.append(e)
                if hist.count > 3 { hist.removeFirst(hist.count - 3) }
                lastByKey[key] = hist
                if hist.count == 3, let a = hist[0].window, hist[2].window == a, hist[1].window != a,
                   hist[2].t - hist[0].t <= withinMs || hist[2].t - hist[1].t <= withinMs {
                    out.append(["pid": Int(e.pid), "kind": e.kind, "window": a, "via": hist[1].window ?? NSNull(),
                                "lostAt": hist[1].t, "regainedAt": hist[2].t, "gapMs": (hist[2].t - hist[1].t).rounded(),
                                "seq": [hist[1].seq, hist[2].seq]])
                }
            }
        }
        // App-level: deactivated then activated again quickly.
        var deact: [Int32: FocusChange] = [:]
        for e in events {
            if e.kind == "appDeactivated" { deact[e.pid] = e }
            if e.kind == "appActivated", let d = deact[e.pid], e.t - d.t <= withinMs {
                out.append(["pid": Int(e.pid), "kind": "appReactivated", "lostAt": d.t, "regainedAt": e.t,
                            "gapMs": (e.t - d.t).rounded(), "seq": [d.seq, e.seq]])
                deact[e.pid] = nil
            }
        }
        return out
    }
}

/// One accessibility node, reduced to what the Notification Center rule needs.
public struct AXLite {
    public let role: String
    public let subrole: String
    public let width: Double
    public let height: Double
    public let label: String

    public init(role: String, subrole: String, width: Double, height: Double, label: String) {
        self.role = role; self.subrole = subrole; self.width = width; self.height = height; self.label = label
    }
}

public enum NotificationCenterRule {
    /// Notification Center keeps a full-display window (layer 21, title "Notification Center")
    /// around while nothing is showing; CGWindowList may report it on screen. It only shows
    /// something when its AX tree has visible content: banners and alerts
    /// (AXNotificationCenterBanner / AXNotificationCenterAlert…), or the open panel's widgets
    /// and notification list (text, buttons, images with a size).
    public static func content(_ nodes: [AXLite]) -> (visible: Bool, banners: [String], alerts: [String], other: Int) {
        var banners: [String] = [], alerts: [String] = [], other = 0
        for n in nodes where n.width > 0 && n.height > 0 {
            if n.subrole.hasPrefix("AXNotificationCenterAlert") { alerts.append(n.label) }
            else if n.subrole.hasPrefix("AXNotificationCenter") { banners.append(n.label) }
            else if ["AXStaticText", "AXButton", "AXImage", "AXCheckBox", "AXTextField"].contains(n.role) { other += 1 }
        }
        return (!banners.isEmpty || !alerts.isEmpty || other > 0, banners, alerts, other)
    }
}

/// A status item (AXExtrasMenuBar child) for status_items / click_status_item.
public struct StatusItemRef: Equatable {
    public let pid: Int32
    public let bundleId: String
    public let name: String
    public let index: Int          // position among this app's status items
    public let x: Double           // left edge, for ordering

    public init(pid: Int32, bundleId: String, name: String, index: Int, x: Double) {
        self.pid = pid; self.bundleId = bundleId; self.name = name; self.index = index; self.x = x
    }
}

public enum StatusItemPick {
    /// Items whose app matches [app]: a pid ("1234"), an exact bundle id, or an app name
    /// (case-insensitive). nil matches everything.
    public static func filter(_ items: [StatusItemRef], app: String?) -> [StatusItemRef] {
        guard let app, !app.isEmpty else { return items }
        if let pid = Int32(app) { return items.filter { $0.pid == pid } }
        let byBundle = items.filter { $0.bundleId == app }
        if !byBundle.isEmpty { return byBundle }
        return items.filter { $0.name.caseInsensitiveCompare(app) == .orderedSame }
    }

    /// Exactly one item: [pid] beats [app]; when several processes match, the caller must say
    /// which (the error lists them).
    public static func pick(_ items: [StatusItemRef], pid: Int32?, app: String?, index: Int) throws -> StatusItemRef {
        var c = items
        if let pid { c = c.filter { $0.pid == pid } } else { c = filter(c, app: app) }
        if c.isEmpty { throw ToolError("no status item matches \(pid.map { "pid \($0)" } ?? "'\(app ?? "")'")") }
        let pids = Array(Set(c.map(\.pid))).sorted()
        if pids.count > 1 {
            let who = pids.map { p in "\(p) (\(c.first { $0.pid == p }!.bundleId))" }.joined(separator: ", ")
            throw ToolError("several processes match: \(who) — pass pid")
        }
        guard let hit = c.first(where: { $0.index == index }) else {
            throw ToolError("status item index \(index) not found (the app has \(c.count))")
        }
        return hit
    }
}
