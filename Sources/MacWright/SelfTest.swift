// selftest: posts input and checks what a tap actually received.
//
// Suites:
//   mouse  a short out-and-back move (+ optional click) seen by a session tap; the events are real.
//          Results are read after a fence (see Recorder.swift), so slow delivery is waited for.
//   keys   modifier chords, click modifiers and type_text, checked at the HID tap (where HID-level apps
//          listens) against the KeyFlags model; MacWright's events are swallowed there, so no app
//          receives them.
//   force  force_click, checked at the HID tap for a type-29 gesture whose NSEvent is a pressure
//          event (type 34) reaching stage 2; swallowed too.
import AppKit
import CoreGraphics
import Foundation
import MacWrightCore

enum SelfTest {
    /// Modifier bits compared between expectation and delivery (macOS adds unrelated bits on post).
    static let modMask: UInt64 = 0x00FF_0000 | 0x0000_207F

    static func run(suite: String, at point: CGPoint?, click: Bool) throws -> [String: Any] {
        switch suite {
        case "mouse": return try mouse(at: point, click: click)
        case "keys": return try keys()
        case "force": return try force()
        case "all":
            let parts = [try mouse(at: point, click: click), try keys(), try force()]
            return ["suite": "all", "pass": parts.allSatisfy { $0["pass"] as? Bool == true }, "suites": parts]
        default: throw ToolError("suite must be mouse, keys, force or all")
        }
    }

    /// Runs [action] with a swallowing HID recorder and returns MacWright's events it saw.
    private static func atHID(full: Bool = false, _ action: () throws -> Void) throws -> [Recorded] {
        let rec = EventRecorder(fullFields: full)
        try rec.start(["hid"], swallowSynthetic: true)
        defer { rec.stop() }
        guard rec.waitLive() else { throw ToolError("HID tap did not come up") }
        try action()
        let f = rec.fence()
        if !f.seen { throw ToolError("the HID tap never saw MacWright's fence (\(Int(f.ms)) ms): results would be incomplete") }
        return rec.results().filter(\.synthetic)
    }

    // MARK: mouse

    static func mouse(at point: CGPoint?, click: Bool) throws -> [String: Any] {
        let rec = EventRecorder(fullFields: false)
        try rec.start(["session"])
        defer { rec.stop() }
        let live = rec.waitLive()
        let d = Driver.shared
        d.sync()
        let start = d.pos
        // A short out-and-back move, so the cursor ends where it started.
        try d.moveBy([CGVector(dx: 6, dy: 0), CGVector(dx: 6, dy: 0), CGVector(dx: -6, dy: 0), CGVector(dx: -6, dy: 0)], intervalMs: 10)
        if click {
            if let point { try d.warp(point) }
            try d.click(.left, count: 1)
        }
        let fence = rec.fence()
        let ev = rec.results().filter(\.synthetic)
        let movesWithDelta = ev.filter { [5, 6].contains($0.type) && ($0.ints[4] != nil || $0.ints[5] != nil) }.count
        let downs = ev.filter { $0.type == 1 }.count, ups = ev.filter { $0.type == 2 }.count
        let pass = movesWithDelta >= 4 && (!click || (downs >= 1 && ups >= 1))
        var out: [String: Any] = [
            "suite": "mouse", "pass": pass, "tapLive": live, "start": start,
            "fence": ["seen": fence.seen, "ms": fence.ms],
            "seen": ["movesWithDelta": movesWithDelta, "leftDown": downs, "leftUp": ups],
            "expected": ["movesWithDelta": 4, "leftDown": click ? 1 : 0, "leftUp": click ? 1 : 0],
        ]
        if !fence.seen {
            out["note"] = "The session tap never saw MacWright's fence event, so it is not receiving MacWright's events at all (another app's tap consuming them?)."
        }
        let disabled = rec.disabledCounts
        if !disabled.isEmpty { out["tapDisabled"] = disabled }
        return out
    }

    // MARK: keys

    static func keys() throws -> [String: Any] {
        let d = Driver.shared
        var cases: [[String: Any]] = []
        let combos: [[KeyMap.Modifier]] = [[.cmd], [.opt], [.shift], [.ctrl], [.cmd, .shift], [.ctrl, .opt], [.cmd, .opt]]
        for mods in combos {
            let seen = try atHID { try d.key(0x00, mods: mods, holdMs: 20) }.filter { [10, 11, 12].contains($0.type) }
            cases.append(compare(name: "a+" + mods.map(\.rawValue).joined(separator: "+"),
                                 expected: KeyFlags.chord(0x00, mods: mods), seen: seen))
        }
        // An arrow carries NumericPad + SecondaryFn on top of its modifiers.
        let arrow = try atHID { try d.key(0x7B, mods: [.cmd, .shift], holdMs: 20) }.filter { [10, 11, 12].contains($0.type) }
        cases.append(compare(name: "left+cmd+shift", expected: KeyFlags.chord(0x7B, mods: [.cmd, .shift]), seen: arrow))

        // Click modifiers: the mouse down/up carry Cmd, wrapped in Cmd's flagsChanged.
        let clickSeen = try atHID {
            try d.pressModifiers([.cmd])
            defer { d.releaseModifiers([.cmd]) }
            try d.click(.left, count: 1)
        }
        let buttons = clickSeen.filter { [1, 2].contains($0.type) }
        let clickPass = buttons.count == 2 && buttons.allSatisfy { $0.flags & EventFlag.command != 0 }
            && clickSeen.filter { $0.type == 12 && $0.keyCode == 0x37 }.count == 2
        cases.append(["name": "click+cmd", "pass": clickPass, "seen": clickSeen.filter { $0.type != 5 }.map(\.compact)])

        // type_text: a real Shift press around capitals and shifted symbols, chars carried.
        let typed = try atHID { try d.type("Hi!", intervalMs: 5) }.filter { [10, 11, 12].contains($0.type) }
        let downs = typed.filter { $0.type == 10 }
        let shiftPresses = typed.filter { $0.type == 12 && $0.keyCode == 0x38 }
        func chars(_ r: Recorded) -> String? { r.ns?["characters"] as? String }
        let typePass = downs.count == 3
            && downs[0].keyCode == 0x04 && downs[0].flags & EventFlag.shift != 0 && chars(downs[0]) == "H"
            && downs[1].keyCode == 0x22 && downs[1].flags & EventFlag.shift == 0 && chars(downs[1]) == "i"
            && downs[2].keyCode == 0x12 && downs[2].flags & EventFlag.shift != 0 && chars(downs[2]) == "!"
            && shiftPresses.count == 4
        cases.append(["name": "type_text Hi!", "pass": typePass, "seen": typed.map(\.compact)])

        return ["suite": "keys", "pass": cases.allSatisfy { $0["pass"] as? Bool == true }, "cases": cases,
                "note": "Checked at the HID tap; MacWright's events were swallowed there, so no app received them."]
    }

    /// Same kinds, keycodes and modifier bits, in the same order.
    static func compare(name: String, expected: [SynthKey], seen: [Recorded]) -> [String: Any] {
        func kind(_ t: UInt32) -> SynthKey.Kind? { t == 12 ? .flagsChanged : t == 10 ? .keyDown : t == 11 ? .keyUp : nil }
        let got = seen.map { (kind($0.type), CGKeyCode($0.keyCode), $0.flags & modMask) }
        let want = expected.map { ($0.kind as SynthKey.Kind?, $0.keyCode, $0.flags & modMask) }
        let pass = got.count == want.count && zip(got, want).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 }
        var o: [String: Any] = ["name": name, "pass": pass]
        if pass {
            o["sequence"] = expected.map(\.description)
        } else {
            o["expected"] = expected.map(\.description)
            o["seen"] = seen.map(\.compact)
        }
        return o
    }

    // MARK: force

    static func force() throws -> [String: Any] {
        let seen = try atHID(full: true) { try Driver.shared.forceClick() }
        let gestures = seen.filter { $0.type == 29 }
        let stages = gestures.compactMap { $0.ns?["stage"] as? Int }
        let pressureEvents = gestures.filter { $0.ns?["type"] as? Int == 34 }
        let pass = seen.contains { $0.type == 1 } && seen.contains { $0.type == 2 }
            && !pressureEvents.isEmpty && (stages.max() ?? 0) >= 2
        return ["suite": "force", "pass": pass,
                "seen": ["leftDown": seen.filter { $0.type == 1 }.count, "leftUp": seen.filter { $0.type == 2 }.count,
                         "gestureEvents": gestures.count, "pressureEvents": pressureEvents.count, "stages": stages],
                "events": summarize(seen),
                "sampleStage2": gestures.first { $0.ns?["stage"] as? Int == 2 }.map(\.full) as Any? ?? NSNull(),
                "note": "Checked at the HID tap; swallowed there, so nothing was clicked."]
    }
}
