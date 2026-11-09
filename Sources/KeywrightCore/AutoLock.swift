// When Keywright locks itself: after a stretch with no tool calls, and at most a fixed time after
// the owner unlocked it, whichever comes first. Either limit can be off (0).
import Foundation

public struct AutoLockLimits: Equatable, Sendable {
    /// Minutes without a tool call before locking; 0 = never.
    public var idleMinutes: Int
    /// Hours after unlocking before locking, busy or not; 0 = never.
    public var maxHours: Int

    public static let defaults = AutoLockLimits(idleMinutes: 15, maxHours: 4)
    public static let idleChoices = [0, 5, 15, 30, 60, 120]
    public static let maxChoices = [0, 1, 2, 4, 8, 12]

    public init(idleMinutes: Int, maxHours: Int) {
        self.idleMinutes = max(0, idleMinutes)
        self.maxHours = max(0, maxHours)
    }

    /// Why to lock now, or nil. A call that is running counts as activity, so a long recording
    /// never trips the idle limit; the hard limit applies regardless.
    public func reason(now: Date, unlockedAt: Date, lastActivity: Date, busy: Bool) -> String? {
        if maxHours > 0, now.timeIntervalSince(unlockedAt) >= Double(maxHours) * 3600 {
            return "unlocked for \(maxHours) h (the limit)"
        }
        if idleMinutes > 0, !busy, now.timeIntervalSince(lastActivity) >= Double(idleMinutes) * 60 {
            return "no tool calls for \(idleMinutes) min"
        }
        return nil
    }

    /// Seconds until the next automatic lock (ignoring future activity), or nil when both are off.
    public func remaining(now: Date, unlockedAt: Date, lastActivity: Date, busy: Bool) -> TimeInterval? {
        var r: [TimeInterval] = []
        if maxHours > 0 { r.append(Double(maxHours) * 3600 - now.timeIntervalSince(unlockedAt)) }
        if idleMinutes > 0, !busy { r.append(Double(idleMinutes) * 60 - now.timeIntervalSince(lastActivity)) }
        return r.min().map { max(0, $0) }
    }

    /// True when [new] keeps Keywright unlocked longer than [old] in some case (a limit raised or
    /// turned off): that needs the owner's Touch ID, so an agent clicking the menu can't do it.
    public static func loosens(_ old: Int, _ new: Int) -> Bool {
        if old == 0 { return false }      // already off: anything is stricter or equal
        return new == 0 || new > old
    }

    public func loosens(to new: AutoLockLimits) -> Bool {
        Self.loosens(idleMinutes, new.idleMinutes) || Self.loosens(maxHours, new.maxHours)
    }

    /// e.g. "after 15 min idle, at most 4 h"
    public var summary: String {
        let idle = idleMinutes > 0 ? "after \(idleMinutes) min idle" : "never when idle"
        let cap = maxHours > 0 ? "at most \(maxHours) h" : "no time cap"
        return "\(idle), \(cap)"
    }
}
