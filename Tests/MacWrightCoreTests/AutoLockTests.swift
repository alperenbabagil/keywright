import XCTest
@testable import MacWrightCore

final class AutoLockTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func testIdleLimit() {
        let l = AutoLockLimits(idleMinutes: 15, maxHours: 0)
        XCTAssertNil(l.reason(now: at(14 * 60), unlockedAt: t0, lastActivity: t0, busy: false))
        XCTAssertEqual(l.reason(now: at(15 * 60), unlockedAt: t0, lastActivity: t0, busy: false), "no tool calls for 15 min")
        // Activity resets it; a running call is activity.
        XCTAssertNil(l.reason(now: at(20 * 60), unlockedAt: t0, lastActivity: at(10 * 60), busy: false))
        XCTAssertNil(l.reason(now: at(60 * 60), unlockedAt: t0, lastActivity: t0, busy: true))
    }

    func testHardLimitAppliesEvenWhileBusy() {
        let l = AutoLockLimits(idleMinutes: 15, maxHours: 4)
        XCTAssertNil(l.reason(now: at(4 * 3600 - 1), unlockedAt: t0, lastActivity: at(4 * 3600 - 2), busy: true))
        XCTAssertEqual(l.reason(now: at(4 * 3600), unlockedAt: t0, lastActivity: at(4 * 3600), busy: true), "unlocked for 4 h (the limit)")
    }

    func testOff() {
        let l = AutoLockLimits(idleMinutes: 0, maxHours: 0)
        XCTAssertNil(l.reason(now: at(1e7), unlockedAt: t0, lastActivity: t0, busy: false))
        XCTAssertNil(l.remaining(now: at(5), unlockedAt: t0, lastActivity: t0, busy: false))
    }

    func testRemainingIsTheSoonerLimit() {
        let l = AutoLockLimits(idleMinutes: 15, maxHours: 1)
        XCTAssertEqual(l.remaining(now: at(50 * 60), unlockedAt: t0, lastActivity: at(49 * 60), busy: false), 10 * 60)
        XCTAssertEqual(l.remaining(now: at(10 * 60), unlockedAt: t0, lastActivity: at(10 * 60), busy: false), 15 * 60)
        XCTAssertEqual(l.remaining(now: at(10 * 60), unlockedAt: t0, lastActivity: t0, busy: true), 50 * 60)
    }

    func testLoosening() {
        let d = AutoLockLimits.defaults
        XCTAssertFalse(d.loosens(to: AutoLockLimits(idleMinutes: 5, maxHours: 1)))   // stricter
        XCTAssertFalse(d.loosens(to: d))
        XCTAssertTrue(d.loosens(to: AutoLockLimits(idleMinutes: 30, maxHours: 4)))   // longer idle
        XCTAssertTrue(d.loosens(to: AutoLockLimits(idleMinutes: 15, maxHours: 0)))   // cap turned off
        XCTAssertTrue(d.loosens(to: AutoLockLimits(idleMinutes: 0, maxHours: 4)))    // idle turned off
        XCTAssertFalse(AutoLockLimits(idleMinutes: 0, maxHours: 0).loosens(to: d))  // from off: stricter
    }
}
