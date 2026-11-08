import CoreGraphics
import XCTest
@testable import MacWrightCore

final class KeyMapTests: XCTestCase {
    func testNamedKeys() throws {
        XCTAssertEqual(try KeyMap.keyCode("esc"), 0x35)
        XCTAssertEqual(try KeyMap.keyCode("return"), 0x24)
        XCTAssertEqual(try KeyMap.keyCode("tab"), 0x30)
        XCTAssertEqual(try KeyMap.keyCode("space"), 0x31)
        XCTAssertEqual(try KeyMap.keyCode("delete"), 0x33)
        XCTAssertEqual(try KeyMap.keyCode("left"), 0x7B)
        XCTAssertEqual(try KeyMap.keyCode("up"), 0x7E)
        XCTAssertEqual(try KeyMap.keyCode("f1"), 0x7A)
        XCTAssertEqual(try KeyMap.keyCode("f12"), 0x6F)
        XCTAssertEqual(try KeyMap.keyCode("a"), 0x00)
        XCTAssertEqual(try KeyMap.keyCode("z"), 0x06)
        XCTAssertEqual(try KeyMap.keyCode("0"), 0x1D)
        XCTAssertEqual(try KeyMap.keyCode("5"), 0x17)
    }

    func testAliasesAndCase() throws {
        XCTAssertEqual(try KeyMap.keyCode("Escape"), 0x35)
        XCTAssertEqual(try KeyMap.keyCode("ENTER"), 0x24)
        XCTAssertEqual(try KeyMap.keyCode("backspace"), 0x33)
        XCTAssertEqual(try KeyMap.keyCode("arrow_down"), 0x7D)
        XCTAssertEqual(try KeyMap.keyCode("A"), 0x00)
    }

    func testRawKeycodes() throws {
        XCTAssertEqual(try KeyMap.keyCode("53"), 53)
        XCTAssertEqual(try KeyMap.keyCode("0x35"), 0x35)
        XCTAssertEqual(try KeyMap.keyCode("keycode:36"), 36)
    }

    func testUnknown() {
        XCTAssertThrowsError(try KeyMap.keyCode("nope"))
        XCTAssertThrowsError(try KeyMap.keyCode("999"))
        XCTAssertThrowsError(try KeyMap.modifier("hyper"))
    }

    func testModifiers() throws {
        XCTAssertEqual(try KeyMap.modifier("cmd"), .cmd)
        XCTAssertEqual(try KeyMap.modifier("Option"), .opt)
        XCTAssertEqual(try KeyMap.modifier("alt"), .opt)
        XCTAssertEqual(try KeyMap.modifier("control"), .ctrl)
        let f = KeyMap.flags([.cmd, .shift])
        XCTAssertTrue(f.contains(.maskCommand))
        XCTAssertTrue(f.contains(.maskShift))
        XCTAssertFalse(f.contains(.maskAlternate))
        XCTAssertEqual(KeyMap.Modifier.fn.keyCode, 0x3F)
    }

    func testUSKeyForTyping() {
        XCTAssertEqual(KeyMap.usKey(for: "a")?.code, 0x00)
        XCTAssertEqual(KeyMap.usKey(for: "a")?.shift, false)
        XCTAssertEqual(KeyMap.usKey(for: "A")?.code, 0x00)
        XCTAssertEqual(KeyMap.usKey(for: "A")?.shift, true)
        XCTAssertEqual(KeyMap.usKey(for: "!")?.code, 0x12)
        XCTAssertEqual(KeyMap.usKey(for: "!")?.shift, true)
        XCTAssertEqual(KeyMap.usKey(for: " ")?.code, 0x31)
        XCTAssertNil(KeyMap.usKey(for: "ş"))
        XCTAssertNil(KeyMap.usKey(for: "😀"))
    }
}
