import MCP
import XCTest
@testable import KeywrightCore

/// Numbers from a tool call go into Int(), UInt32() and usleep(), which crash on NaN, infinity or
/// huge values, so Args refuses them with an error instead.
final class ArgsTests: XCTestCase {
    func testRefusesNumbersThatWouldCrash() {
        for v: Value in [.string("nan"), .string("inf"), .string("-inf"), .double(1e300), .double(-1e13)] {
            XCTAssertThrowsError(try Args(["ms": v]).double("ms"), "\(v)")
            XCTAssertThrowsError(try Args(["ms": v]).int("ms"), "\(v)")
        }
        XCTAssertEqual(try Args(["ms": .double(1e12)]).int("ms"), 1_000_000_000_000)
        XCTAssertEqual(try Args(["ms": .string("250")]).double("ms"), 250)
    }

    func testSleepClampsInsteadOfCrashing() {
        let t = Date()
        sleepMs(-5)
        sleepMs(.nan)
        sleepMs(20)
        XCTAssertLessThan(Date().timeIntervalSince(t), 0.5)
        XCTAssertEqual(clampedSleepMs(1e12), 600_000)
        XCTAssertEqual(clampedSleepMs(.infinity), 600_000)
        XCTAssertEqual(clampedSleepMs(.nan), 0)
        XCTAssertEqual(clampedSleepMs(-1), 0)
    }
}
