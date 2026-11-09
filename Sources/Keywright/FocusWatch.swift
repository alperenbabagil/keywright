// watch_focus: a timeline of frontmost-app changes (NSWorkspace) and key/main-window changes
// inside apps (AX observers: kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification).
// It catches what a screenshot cannot: a window that loses key and gets it back within ~150 ms
// while its app stays frontmost.
//
// AX observers live on their own run-loop thread (not the main thread, which draws the menu).
// Observed apps: the frontmost one at start, every app that becomes frontmost while watching,
// and any app named in `apps`.
import AppKit
import ApplicationServices
import Foundation
import KeywrightCore

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

final class FocusWatch: @unchecked Sendable {
    static let shared = FocusWatch()

    private struct Entry {
        let change: FocusChange
        let json: [String: Any]
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var seq = 0
    private var dropped = 0
    private let maxEntries = 5000
    private var startUptime: UInt64 = 0
    private var startedAt: Date?
    private var running = false
    private var loop: CFRunLoop?
    private var observers: [pid_t: AXObserver] = [:]
    private var tokens: [NSObjectProtocol] = []
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "keywright.focus"
        return q
    }()

    // MARK: Control

    func start(apps: [String], clear: Bool) throws -> [String: Any] {
        try AX.requireTrusted()
        if lock.withLock({ running }) {
            if clear { lock.withLock { entries.removeAll(); dropped = 0 } }
            for a in apps { observe(try Apps.running(a)) }
            return state()
        }
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            self?.lock.withLock { self?.loop = CFRunLoopGetCurrent() }
            // Keep the run loop alive while no observer is attached yet.
            let keepAlive = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0) { _ in }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), keepAlive, .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "keywright.focus"
        t.qualityOfService = .userInteractive
        t.start()
        ready.wait()
        lock.withLock {
            entries.removeAll(); dropped = 0
            running = true
            startUptime = DispatchTime.now().uptimeNanoseconds
            startedAt = Date()
        }
        let nc = NSWorkspace.shared.notificationCenter
        let names: [(Notification.Name, String)] = [(NSWorkspace.didActivateApplicationNotification, "appActivated"),
                                                    (NSWorkspace.didDeactivateApplicationNotification, "appDeactivated")]
        var toks: [NSObjectProtocol] = []
        for (name, kind) in names {
            toks.append(nc.addObserver(forName: name, object: nil, queue: queue) { [weak self] n in
                guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self.add(kind: kind, app: app, window: nil)
                if kind == "appActivated" { self.observe(app) }
            })
        }
        lock.withLock { tokens = toks }
        // Where things stand now.
        if let front = NSWorkspace.shared.frontmostApplication {
            observe(front)
            var win: AXUIElement?
            if front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                let appEl = AXUIElementCreateApplication(front.processIdentifier)
                AXUIElementSetMessagingTimeout(appEl, 0.5)
                win = AX.attr(appEl, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
            }
            add(kind: "initial", app: front, window: win.map { windowInfo($0) } ?? [:])
        }
        for a in apps { observe(try Apps.running(a)) }
        Log.write("focus watch started")
        return state()
    }

    func stop() -> [String: Any] {
        let (toks, obs, l) = lock.withLock { () -> ([NSObjectProtocol], [pid_t: AXObserver], CFRunLoop?) in
            let r = (tokens, observers, loop)
            tokens = []; observers = [:]; loop = nil; running = false
            return r
        }
        for t in toks { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        if let l {
            for (_, o) in obs { CFRunLoopRemoveSource(l, AXObserverGetRunLoopSource(o), .defaultMode) }
            CFRunLoopStop(l)
        }
        Log.write("focus watch stopped")
        return state()
    }

    func read(since: Int, limit: Int, bounceMs: Double) -> [String: Any] {
        let (picked, all, more) = lock.withLock { () -> ([Entry], [FocusChange], Bool) in
            let after = entries.filter { $0.change.seq > since }
            return (Array(after.prefix(limit)), entries.map(\.change), after.count > limit)
        }
        var o = state()
        o["events"] = picked.map(\.json)
        o["next"] = picked.last?.change.seq ?? since
        if more { o["more"] = true }
        let sinceChanges = all.filter { $0.seq > since }
        o["bounces"] = FocusBounce.detect(sinceChanges, withinMs: bounceMs)
        return o
    }

    func state() -> [String: Any] {
        lock.withLock {
            var o: [String: Any] = ["running": running, "observedPids": observers.keys.map { Int($0) }.sorted(),
                                    "buffered": entries.count, "lastSeq": seq]
            if dropped > 0 { o["dropped"] = dropped }
            if let startedAt { o["startedAt"] = ISO8601DateFormatter().string(from: startedAt) }
            return o
        }
    }

    // MARK: Recording

    private func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds - startUptime) / 1e6 }

    private func add(kind: String, app: NSRunningApplication?, pid: pid_t? = nil, window: [String: Any]?) {
        let p = app?.processIdentifier ?? pid ?? 0
        let running = app ?? NSRunningApplication(processIdentifier: p)
        let label: String? = window.flatMap { w in
            if let id = w["windowId"] as? Int { return "#\(id)" }
            if let t = w["title"] as? String { return t }
            return nil
        }
        lock.withLock {
            guard self.running else { return }
            seq += 1
            let t = (now() * 10).rounded() / 10
            var j: [String: Any] = ["seq": seq, "t": t, "atMillis": Int64(Date().timeIntervalSince1970 * 1000), "kind": kind,
                                    "pid": Int(p), "bundleId": running?.bundleIdentifier ?? "", "app": running?.localizedName ?? ""]
            if let window { j["window"] = window.isEmpty ? NSNull() : window }
            entries.append(Entry(change: FocusChange(seq: seq, t: t, kind: kind, pid: p, window: label), json: j))
            if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries); dropped += 1 }
        }
    }

    /// Window id (CGWindowID, as list_windows shows it), title, subrole and frame.
    private func windowInfo(_ e: AXUIElement) -> [String: Any] {
        var w: [String: Any] = [:]
        var id: CGWindowID = 0
        if _AXUIElementGetWindow(e, &id) == .success, id != 0 { w["windowId"] = Int(id) }
        if let t = AX.str(e, kAXTitleAttribute) { w["title"] = t }
        if let r = AX.str(e, kAXRoleAttribute), r != kAXWindowRole { w["role"] = r }
        if let s = AX.str(e, kAXSubroleAttribute) { w["subrole"] = s }
        if let f = AX.frame(e) { w["bounds"] = f }
        return w
    }

    /// Attaches focused/main-window observers to [app] (once per pid).
    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        let l: CFRunLoop? = lock.withLock { observers[pid] == nil && observers.count < 40 ? loop : nil }
        guard let l else { return }
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let me = Unmanaged<FocusWatch>.fromOpaque(refcon).takeUnretainedValue()
            me.axEvent(element, notification as String)
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.5)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var any = false
        for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            if AXObserverAddNotification(obs, appEl, n as CFString, refcon) == .success { any = true }
        }
        guard any else { return }
        CFRunLoopAddSource(l, AXObserverGetRunLoopSource(obs), .defaultMode)
        CFRunLoopWakeUp(l)
        lock.withLock { observers[pid] = obs }
    }

    /// Focus thread: one AX notification.
    private func axEvent(_ element: AXUIElement, _ notification: String) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        let kind = notification == kAXMainWindowChangedNotification ? "mainWindowChanged" : "focusedWindowChanged"
        // The element is usually the window that became focused/main. Some apps post it on the
        // application element instead: then ask the app which window it is now (none → null).
        var target: AXUIElement? = element
        if AX.str(element, kAXRoleAttribute) == kAXApplicationRole {
            let attr = kind == "mainWindowChanged" ? kAXMainWindowAttribute : kAXFocusedWindowAttribute
            target = AX.attr(element, attr).map { $0 as! AXUIElement }
        }
        add(kind: kind, app: nil, pid: pid, window: target.map { windowInfo($0) } ?? [:])
    }
}
