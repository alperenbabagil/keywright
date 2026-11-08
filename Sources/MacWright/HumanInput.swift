// Always-on, listen-only HID tap that counts input MacWright did not post: the human moving the
// mouse, touching the trackpad, typing — or another app posting events. MacWright's own events
// carry its marker in kCGEventSourceUserData (see Marker), so everything else is someone else's.
//
// It only counts (kind, time, posting pid); it keeps no key codes or characters. Every tool result
// gets `humanInput` from here, and input tools can refuse to run while the human is active
// (`humanQuietMs`).
import AppKit
import CoreGraphics
import Foundation
import MacWrightCore

final class HumanInput: @unchecked Sendable {
    static let shared = HumanInput()

    private let lock = NSLock()
    private let startLock = NSLock()
    private var log = HumanInputLog()
    private var tap: CFMachPort?
    private var loop: CFRunLoop?
    private var disabled: [String: Int] = [:]
    private var startedAt: Date?
    private let ownPid = ProcessInfo.processInfo.processIdentifier

    /// Starts the tap if it isn't running (needs Input Monitoring). Safe to call often.
    @discardableResult
    func ensureStarted() -> Bool {
        startLock.lock()
        defer { startLock.unlock() }
        if live { return true }
        var mask: CGEventMask = 0
        for t in [1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 14, 22, 25, 26, 27, 29] { mask |= 1 << CGEventMask(t) }
        let cb: CGEventTapCallBack = { _, type, event, info in
            let me = Unmanaged<HumanInput>.fromOpaque(info!).takeUnretainedValue()
            me.handle(type, event)
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: cb,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            self?.lock.withLock { self?.loop = CFRunLoopGetCurrent() }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "macwright.human-input"
        t.qualityOfService = .userInteractive
        t.start()
        ready.wait()
        lock.withLock { tap = port; startedAt = Date() }
        Log.write("human-input monitor started")
        return true
    }

    /// Tap thread: field reads and a counter bump only.
    private func handle(_ type: CGEventType, _ e: CGEvent) {
        if type.rawValue >= 0xFFFF_FFFE {
            let why = type == .tapDisabledByTimeout ? "timeout" : "userInput"
            let port = lock.withLock { () -> CFMachPort? in disabled[why, default: 0] += 1; return tap }
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }
        guard !Marker.isOwn(e.getIntegerValueField(.eventSourceUserData)), let kind = InputKind.of(type.rawValue) else { return }
        let pid = Int32(truncatingIfNeeded: e.getIntegerValueField(.eventSourceUnixProcessID))
        let now = Date().timeIntervalSince1970 * 1000
        lock.withLock { log.add(kind: kind, atMillis: now, sourcePid: pid, ownPid: ownPid) }
    }

    var live: Bool { lock.withLock { tap != nil } }

    /// Milliseconds since the last human event, nil when none was seen.
    var msSinceLast: Double? {
        lock.withLock { log.lastAtMillis }.map { Date().timeIntervalSince1970 * 1000 - $0 }
    }

    /// Throws when human input arrived within [ms] (the `humanQuietMs` guard).
    func requireQuiet(_ ms: Double) throws {
        guard ms > 0 else { return }
        ensureStarted()
        let (seen, kind, ago) = lock.withLock { () -> (Bool, String?, Double?) in
            let now = Date().timeIntervalSince1970 * 1000
            return (log.seen(withinMs: ms, nowMillis: now), log.lastKind, log.lastAtMillis.map { now - $0 })
        }
        if seen {
            throw ToolError("human input (\(kind ?? "?")) \(Int(ago ?? 0)) ms ago, within humanQuietMs \(Int(ms)): nothing was posted. Wait for the human to stop, or lower humanQuietMs.")
        }
    }

    /// The `humanInput` block for a tool result. [advance] moves the "since last call" mark
    /// (once per tool call). [duringFrom] is the total at the start of the call.
    func report(advance: Bool, duringFrom: Int? = nil) -> [String: Any] {
        ensureStarted()
        return lock.withLock {
            let total = log.total
            let since = advance ? log.takeSinceMark() : log.peekSinceMark()
            var o: [String: Any] = ["sinceLastCall": since.count, "live": tap != nil]
            if !since.kinds.isEmpty { o["kinds"] = since.kinds }
            if let duringFrom { o["duringCall"] = total - duringFrom }
            if let last = log.lastAtMillis {
                o["lastAtMillis"] = Int64(last)
                o["msAgo"] = Int((Date().timeIntervalSince1970 * 1000 - last).rounded())
                o["lastKind"] = log.lastKind ?? ""
            }
            if !log.byOtherPid.isEmpty {
                o["otherProcesses"] = log.byOtherPid.sorted { $0.value > $1.value }.prefix(5).map { pid, n in
                    ["pid": Int(pid), "events": n, "name": NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""] as [String: Any]
                }
            }
            if !disabled.isEmpty { o["tapDisabled"] = disabled }
            return o
        }
    }

    /// Total so far (to measure one call).
    var total: Int { lock.withLock { log.total } }

    /// Totals since the monitor started, for `status`.
    func summary() -> [String: Any] {
        ensureStarted()
        return lock.withLock {
            var o: [String: Any] = ["live": tap != nil, "total": log.total, "byKind": log.byKind]
            if let startedAt { o["since"] = ISO8601DateFormatter().string(from: startedAt) }
            return o
        }
    }
}
