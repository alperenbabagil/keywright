// Shared run state: lock and pause flags, in-flight tool count and the recent-calls log. Thread-safe;
// the menu observes it through `onChange` (always delivered on the main queue).
import Foundation

struct CallRecord: Identifiable {
    let id = UUID()
    let time: Date
    let tool: String
    let ok: Bool
    let ms: Int
    let note: String
}

final class Control: @unchecked Sendable {
    static let shared = Control()
    private let lock = NSLock()
    private var _paused = false
    /// True until the owner unlocks, and again after Lock or Quit. Starts locked.
    private var _locked = true
    private var _busy = 0
    private var _recent: [CallRecord] = []
    private var _lastActivity = Date()
    /// Fired on the main queue whenever paused/busy/recent change.
    var onChange: (() -> Void)?

    var paused: Bool { lock.withLock { _paused } }
    var locked: Bool { lock.withLock { _locked } }
    var busy: Bool { lock.withLock { _busy > 0 } }
    var recent: [CallRecord] { lock.withLock { _recent } }
    /// When a tool call last started or ended (or the owner unlocked): the idle auto-lock counts from here.
    var lastActivity: Date { lock.withLock { _lastActivity } }

    func touch() { lock.withLock { _lastActivity = Date() } }

    func setPaused(_ p: Bool) {
        lock.withLock { _paused = p }
        if p { Driver.shared.releaseAll() }
        Log.write(p ? "paused" : "resumed")
        changed()
    }

    /// Locking makes every tool call fail, including one already running: its loops check this
    /// between events and frames, and a result that finishes after the lock is thrown away.
    func setLocked(_ l: Bool) {
        lock.withLock { _locked = l }
        if l { Driver.shared.releaseAll() }
        changed()
    }

    func begin() {
        lock.withLock { _busy += 1; _lastActivity = Date() }
        changed()
    }

    func end(_ rec: CallRecord) {
        lock.withLock {
            _busy -= 1
            _lastActivity = Date()
            _recent.insert(rec, at: 0)
            if _recent.count > 40 { _recent.removeLast(_recent.count - 40) }
        }
        changed()
    }

    func clearRecent() {
        lock.withLock { _recent.removeAll() }
        changed()
    }

    private func changed() {
        DispatchQueue.main.async { self.onChange?() }
    }

    /// Throws "locked" or "paused"; checked before and during every action.
    func checkPaused() throws {
        let (l, p) = lock.withLock { (_locked, _paused) }
        if l { throw LockedError() }
        if p { throw PausedError() }
    }

    /// Throws "locked" only; for tools that may run while paused.
    func checkLocked() throws {
        if locked { throw LockedError() }
    }
}

struct LockedError: Error, CustomStringConvertible {
    var description: String { "locked: MacWright is locked, and only its owner can unlock it (Touch ID or the login password)" }
}

struct PausedError: Error, CustomStringConvertible {
    var description: String { "paused: MacWright is paused (menu bar → Pause, or ⌃⌥⌘⎋ to toggle)" }
}

enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacWright")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("macwright.log")
    }()
    private static let queue = DispatchQueue(label: "macwright.log")
    private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func write(_ s: String) {
        let line = "\(fmt.string(from: Date())) \(s)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
