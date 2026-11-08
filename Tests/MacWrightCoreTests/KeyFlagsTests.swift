import CoreGraphics
import XCTest
@testable import MacWrightCore

final class KeyFlagsTests: XCTestCase {
    let nc = EventFlag.nonCoalesced
    let cmd = EventFlag.command | EventFlag.deviceLeftCommand
    let shift = EventFlag.shift | EventFlag.deviceLeftShift
    let opt = EventFlag.alternate | EventFlag.deviceLeftAlternate
    let ctrl = EventFlag.control | EventFlag.deviceLeftControl

    func testPlainKey() {
        XCTAssertEqual(KeyFlags.chord(0x00, mods: []), [SynthKey(.keyDown, 0x00, nc), SynthKey(.keyUp, 0x00, nc)])
    }

    func testCmdA() {
        XCTAssertEqual(KeyFlags.chord(0x00, mods: [.cmd]), [
            SynthKey(.flagsChanged, 0x37, nc | cmd),
            SynthKey(.keyDown, 0x00, nc | cmd),
            SynthKey(.keyUp, 0x00, nc | cmd),
            SynthKey(.flagsChanged, 0x37, nc),
        ])
    }

    func testEachSingleModifier() {
        for (m, code, bits) in [(KeyMap.Modifier.opt, CGKeyCode(0x3A), opt), (.shift, 0x38, shift), (.ctrl, 0x3B, ctrl),
                                (.fn, 0x3F, EventFlag.secondaryFn)] {
            let seq = KeyFlags.chord(0x00, mods: [m])
            XCTAssertEqual(seq.first, SynthKey(.flagsChanged, code, nc | bits), "\(m)")
            XCTAssertEqual(seq[1], SynthKey(.keyDown, 0x00, nc | bits), "\(m)")
            XCTAssertEqual(seq.last, SynthKey(.flagsChanged, code, nc), "\(m)")
        }
    }

    func testTwoModifiersCumulateAndReleaseInReverse() {
        // cmd+shift+left: flags build up press by press, the arrow adds NumericPad + SecondaryFn,
        // and releases drop one modifier at a time in reverse order.
        let arrow = EventFlag.numericPad | EventFlag.secondaryFn
        XCTAssertEqual(KeyFlags.chord(0x7B, mods: [.cmd, .shift]), [
            SynthKey(.flagsChanged, 0x37, nc | cmd),
            SynthKey(.flagsChanged, 0x38, nc | cmd | shift),
            SynthKey(.keyDown, 0x7B, nc | cmd | shift | arrow),
            SynthKey(.keyUp, 0x7B, nc | cmd | shift | arrow),
            SynthKey(.flagsChanged, 0x38, nc | cmd),
            SynthKey(.flagsChanged, 0x37, nc),
        ])
    }

    func testCtrlOpt() {
        let seq = KeyFlags.chord(0x04, mods: [.ctrl, .opt])
        XCTAssertEqual(seq.map(\.kind), [.flagsChanged, .flagsChanged, .keyDown, .keyUp, .flagsChanged, .flagsChanged])
        XCTAssertEqual(seq[2].flags, nc | ctrl | opt)
        XCTAssertEqual(seq[4], SynthKey(.flagsChanged, 0x3A, nc | ctrl))
        XCTAssertEqual(seq[5], SynthKey(.flagsChanged, 0x3B, nc))
    }

    func testAlreadyHeldModifiersAreNotPressedOrReleasedAgain() {
        // Cmd held by an earlier `hold`/`down`: a cmd+shift chord only presses and releases shift,
        // and every event keeps Cmd.
        let seq = KeyFlags.chord(0x00, mods: [.cmd, .shift], held: [.cmd])
        XCTAssertEqual(seq, [
            SynthKey(.flagsChanged, 0x38, nc | cmd | shift),
            SynthKey(.keyDown, 0x00, nc | cmd | shift),
            SynthKey(.keyUp, 0x00, nc | cmd | shift),
            SynthKey(.flagsChanged, 0x38, nc | cmd),
        ])
    }

    func testPressReleaseBookkeeping() {
        let (down, held) = KeyFlags.press([.ctrl, .opt, .cmd], held: [])
        XCTAssertEqual(held, [.ctrl, .opt, .cmd])
        XCTAssertEqual(down.map(\.flags), [nc | ctrl, nc | ctrl | opt, nc | ctrl | opt | cmd])
        let (up, after) = KeyFlags.release([.ctrl, .opt, .cmd], held: held)
        XCTAssertEqual(after, [])
        XCTAssertEqual(up.map(\.keyCode), [0x37, 0x3A, 0x3B])
        XCTAssertEqual(up.map(\.flags), [nc | ctrl | opt, nc | ctrl, nc])
        // Releasing something not held posts nothing.
        XCTAssertEqual(KeyFlags.release([.shift], held: [.cmd]).0, [])
    }

    func testKeySpecificHardwareFlags() {
        XCTAssertEqual(KeyFlags.keyFlags(0x7E), EventFlag.numericPad | EventFlag.secondaryFn)  // up
        XCTAssertEqual(KeyFlags.keyFlags(0x7A), EventFlag.secondaryFn)                         // F1
        XCTAssertEqual(KeyFlags.keyFlags(0x73), EventFlag.secondaryFn)                         // home
        XCTAssertEqual(KeyFlags.keyFlags(0x4C), EventFlag.numericPad)                          // keypad enter
        XCTAssertEqual(KeyFlags.keyFlags(0x00), 0)                                             // a
        XCTAssertEqual(KeyFlags.keyFlags(0x35), 0)                                             // esc
    }

    func testFlagNames() {
        XCTAssertEqual(EventFlag.names(nc | cmd | shift), ["cmd", "shift"])
        XCTAssertEqual(EventFlag.names(nc), [])
    }
}
