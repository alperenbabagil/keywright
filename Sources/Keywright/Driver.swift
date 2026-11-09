// Posts mouse and keyboard events at kCGHIDEventTap, like real hardware.
//
// Relative moves keep Keywright's physical-mouse model: each step posts mouseMoved (or a
// *MouseDragged while a button is held) carrying the delta fields, at a location clamped to the
// displays (sliding along edges), then re-reads the real cursor. An app's edge capture reads
// those deltas, so moves must never be replaced by warps.
import AppKit
import CoreGraphics
import Foundation
import KeywrightCore

/// The live display arrangement, straight from CoreGraphics.
struct LiveLayout: ScreenLayout {
    func onScreen(_ p: CGPoint) -> Bool {
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(p, 0, nil, &count)
        return count > 0
    }
}

enum MouseButton: String, CaseIterable {
    case left, right, middle
    var cg: CGMouseButton { self == .left ? .left : self == .right ? .right : .center }
    var downType: CGEventType { self == .left ? .leftMouseDown : self == .right ? .rightMouseDown : .otherMouseDown }
    var upType: CGEventType { self == .left ? .leftMouseUp : self == .right ? .rightMouseUp : .otherMouseUp }
    var dragType: CGEventType { self == .left ? .leftMouseDragged : self == .right ? .rightMouseDragged : .otherMouseDragged }

    static func parse(_ s: String?) throws -> MouseButton {
        guard let s else { return .left }
        guard let b = MouseButton(rawValue: s.lowercased()) else { throw ToolError("button must be left, right or middle") }
        return b
    }
}

/// CGCursorIsVisible is marked unavailable in the Swift SDK but still exported; look it up at runtime.
private let cgCursorIsVisible: (@convention(c) () -> Int32)? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsVisible") else { return nil }  // RTLD_DEFAULT
    return unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)
}()

/// True while the cursor is hidden system-wide (e.g. an app under test has captured the mouse).
func cursorHidden() -> Bool { cgCursorIsVisible.map { $0() == 0 } ?? false }

final class Driver: @unchecked Sendable {
    static let shared = Driver()

    let src = CGEventSource(stateID: .hidSystemState)
    private let lock = NSLock()
    private var heldButtons: [MouseButton] = []
    private var heldKeys: [CGKeyCode] = []
    private var heldMods: [KeyMap.Modifier] = []
    /// Last known cursor location; re-read from the system after every posted event.
    private(set) var pos = CGEvent(source: nil)?.location ?? .zero

    var cursor: CGPoint { CGEvent(source: nil)?.location ?? pos }

    func sync() { pos = cursor }

    /// After a glide to [target]: the WindowServer sometimes applies the last posted step later than
    /// step() waits, so the tracked spot lags short of it (push_edge dwelt 8 pt before an app's edge
    /// zone, 2026-11-04). Wait up to 50 ms for the cursor, then close any gap with relative steps.
    /// Returns whether the cursor is on [target].
    @discardableResult
    func settle(at target: CGPoint) throws -> Bool {
        func on() -> Bool { abs(pos.x - target.x) < 1 && abs(pos.y - target.y) < 1 }
        for _ in 0..<25 { pos = cursor; if on() { return true }; usleep(2000) }
        if cursorHidden() { return on() }  // frozen by a capture: nothing to correct
        for _ in 0..<3 {
            let (type, button) = moveType()
            try step(type, target.x - pos.x, target.y - pos.y, button: button)
            usleep(10_000); pos = cursor
            if on() { return true }
        }
        return on()
    }

    /// Flags a physical device would put on an event right now: held modifiers (with their
    /// left/right device bits) plus NonCoalesced.
    private var modFlags: CGEventFlags { CGEventFlags(rawValue: lock.withLock { KeyFlags.flags(held: heldMods) }) }

    // MARK: Posting

    /// What one tool call posted, for its result.
    private var log: [(type: UInt32, keyCode: Int?, flags: UInt64)] = []

    func beginLog() { lock.withLock { log.removeAll(); moved = 0; frozen = 0 } }

    /// Relative steps with a non-zero delta since beginLog(), and how many of them left the cursor
    /// where it was although it should have moved (frozen: an app's mouse capture, or a stuck pointer).
    private var moved = 0
    private var frozen = 0

    func pointerSummary() -> [String: Any] {
        let (m, f) = lock.withLock { (moved, frozen) }
        var o: [String: Any] = ["hidden": cursorHidden()]
        if m > 0 { o["relativeSteps"] = m; o["frozenSteps"] = f; o["moves"] = f < m }
        return o
    }

    /// Summary of everything posted since beginLog(): counts by type and the events (mouse moves folded).
    func postedSummary() -> [String: Any] {
        let entries = lock.withLock { log }
        var byType: [String: Int] = [:]
        var list: [[String: Any]] = []
        for e in entries {
            let name = EventNames.name(e.type)
            byType[name, default: 0] += 1
            if [5, 6, 7, 27].contains(e.type), let last = list.last, last["name"] as? String == name {
                list[list.count - 1]["count"] = (last["count"] as? Int ?? 1) + 1
                continue
            }
            var o: [String: Any] = ["name": name, "type": Int(e.type), "flags": String(format: "0x%llx", e.flags)]
            let mods = EventFlag.names(e.flags)
            if !mods.isEmpty { o["mods"] = mods }
            if let k = e.keyCode { o["keyCode"] = k }
            list.append(o)
        }
        if list.count > 80 { list = Array(list.prefix(80)) + [["truncated": list.count - 80]] }
        return ["count": entries.count, "byType": byType, "events": list]
    }

    /// Every synthetic event goes out here: tagged with the Keywright marker (so taps can tell it
    /// from real input), posted at kCGHIDEventTap from the one hidSystemState source, and logged.
    private func post(_ e: CGEvent) {
        e.setIntegerValueField(.eventSourceUserData, value: Marker.synthetic)
        e.post(tap: .cghidEventTap)
        let type = e.type.rawValue
        let key: Int? = [10, 11, 12].contains(type) ? Int(e.getIntegerValueField(.keyboardEventKeycode)) : nil
        lock.withLock { log.append((type, key, e.flags.rawValue)) }
    }

    /// A zero-delta move at the cursor carrying a bookkeeping marker (a probe that wakes up new
    /// taps, or a fence). It is *Dragged while a button is held, so it never looks like a release.
    /// Not logged as posted input.
    func postMarker(_ userData: Int64) {
        let (type, button) = moveType()
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: cursor, mouseButton: button) else { return }
        e.flags = modFlags
        e.setIntegerValueField(.eventSourceUserData, value: userData)
        e.post(tap: .cghidEventTap)
    }

    // MARK: Mouse

    /// One mouse event at [p] carrying the deltas.
    private func postMove(_ type: CGEventType, at p: CGPoint, _ dx: Double, _ dy: Double, button: CGMouseButton) {
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        e.setDoubleValueField(.mouseEventDeltaX, value: dx)
        e.setDoubleValueField(.mouseEventDeltaY, value: dy)
        if button == .center { e.setIntegerValueField(.mouseEventButtonNumber, value: 2) }
        e.flags = modFlags
        post(e)
    }

    /// When the cursor is frozen — a capturing app hides it and freezes it with
    /// CGAssociateMouseAndMouseCursorPosition(0) while it has captured the mouse — the step still
    /// carries its deltas and the tracked position stays at the frozen spot.
    ///
    /// One relative step: clamp to the displays, post with deltas, follow the real cursor.
    func step(_ type: CGEventType, _ dx: Double, _ dy: Double, button: CGMouseButton = .left) throws {
        try Control.shared.checkPaused()
        // A hidden cursor isn't always a frozen one: apps hide it while you type (TextEdit does,
        // until the mouse moves), and assuming the app's capture then left the pointer stuck
        // (2026-11-03). Posting at the new spot while captured moved the hidden cursor around under
        // a live capture, so: post at the current spot with the deltas, as a captured mouse
        // does. That unhides a cursor an app only obscured; then the step goes ahead normally.
        let nonZero = dx != 0 || dy != 0
        if nonZero { lock.withLock { moved += 1 } }
        var sentDeltas = false
        if nonZero && cursorHidden() {
            pos = cursor
            postMove(type, at: pos, dx, dy, button: button)
            usleep(2000)
            if cursorHidden() {
                lock.withLock { frozen += 1 }  // frozen: hidden and held by a capture
                return
            }
            sentDeltas = true  // the deltas are delivered; the follow-up event only moves the cursor
        }
        pos = clampedStep(pos, dx, dy, in: LiveLayout())
        postMove(type, at: pos, sentDeltas ? 0 : dx, sentDeltas ? 0 : dy, button: button)
        // Follow the real cursor, which the system clamps to the screen — like a physical mouse.
        // The WindowServer applies posted events asynchronously, so give it a few ms to catch up:
        // reading too early returns the old spot and the next step would silently lose this one.
        let expected = pos
        var waited = 0
        repeat {
            usleep(waited == 0 ? 2000 : 500)
            waited += 1
            pos = cursor
        } while waited < 13 && (abs(pos.x - expected.x) > 0.5 || abs(pos.y - expected.y) > 0.5)
    }

    /// The event type a relative move should use: dragged while a button is held.
    func moveType() -> (CGEventType, CGMouseButton) {
        guard let b = lock.withLock({ heldButtons.last }) else { return (.mouseMoved, .left) }
        return (b.dragType, b.cg)
    }

    /// Posts [deltas] [intervalMs] apart as relative moves.
    func moveBy(_ deltas: [CGVector], intervalMs: Double) throws {
        let (type, button) = moveType()
        for (i, d) in deltas.enumerated() {
            try step(type, d.dx, d.dy, button: button)
            if i < deltas.count - 1, intervalMs > 0 { sleepMs(intervalMs) }
        }
    }

    /// Glides to (x, y) over [durationMs] with posted deltas; retries briefly if the clamp
    /// (an edge between displays) bent the path. Returns whether the target was reached.
    func moveTo(_ target: CGPoint, durationMs: Double) throws -> Bool {
        sync()
        let interval = 8.0
        var steps = max(1, Int((durationMs / interval).rounded()))
        for _ in 0..<3 {
            let dx = (target.x - pos.x).rounded(), dy = (target.y - pos.y).rounded()
            if dx == 0 && dy == 0 { return true }
            try moveBy(glideDeltas(dx: dx, dy: dy, steps: steps), intervalMs: interval)
            steps = max(1, steps / 4)
        }
        return abs(pos.x - target.x) < 1 && abs(pos.y - target.y) < 1
    }

    func warp(_ p: CGPoint) throws {
        try Control.shared.checkPaused()
        CGWarpMouseCursorPosition(p)
        pos = p
        let (type, button) = moveType()
        try step(type, 0, 0, button: button)
    }

    private func mouseEvent(_ type: CGEventType, _ b: MouseButton, clickState: Int, pressure: Double? = nil) {
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pos, mouseButton: b.cg) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        if b == .middle { e.setIntegerValueField(.mouseEventButtonNumber, value: 2) }
        if let pressure { e.setDoubleValueField(.mouseEventPressure, value: pressure) }
        e.flags = modFlags
        post(e)
    }

    func down(_ b: MouseButton, clickState: Int = 1) throws {
        try Control.shared.checkPaused()
        try SecurityPrompt.refuseIfShowing()
        sync()
        mouseEvent(b.downType, b, clickState: clickState, pressure: 1)
        lock.withLock { if !heldButtons.contains(b) { heldButtons.append(b) } }
        usleep(2000)
    }

    func up(_ b: MouseButton, clickState: Int = 1) {
        sync()
        mouseEvent(b.upType, b, clickState: clickState, pressure: 0)
        lock.withLock { heldButtons.removeAll { $0 == b } }
        usleep(2000)
    }

    func isHeld(_ b: MouseButton) -> Bool { lock.withLock { heldButtons.contains(b) } }

    func click(_ b: MouseButton, count: Int) throws {
        for i in 1...max(1, min(3, count)) {
            try down(b, clickState: i)
            usleep(30_000)
            up(b, clickState: i)
            if i < count { usleep(60_000) }
        }
    }

    /// A Force Touch click, modelled on a recorded trackpad force click (record_events):
    /// gesture began (stage 1, pressure 0) ~30 ms before the left down; stage 1 pressure ramping
    /// 0 → 0.43 every 8 ms (stageTransition rising once pressure passes 0.3); stage 2 from ~130 ms
    /// with pressure restarting at 0 and easing up to 0.7 for [stage2Ms]; ~6 events back at stage 1
    /// (pressure 1, transition ~0.44); gesture ended (stage 0); left up ~50 ms later.
    /// Each pressure event is a CGEvent of type 29 (NSEventTypeGesture) with field 110 = 32
    /// (IOHIDEventTypeForce), 132 = phase, 143 = stage, 148/119/139 = pressure, 147 (+113/114/116/
    /// 118/142) = stageTransition, 123/165 and 115/117/164 = their float bit patterns, 144 = 5 —
    /// NSEvent(cgEvent:) reads them as NSEventTypePressure with that stage. The buttons carry the
    /// trackpad's mouse subtype (touch).
    func forceClick(stage2Ms: Double = 350) throws {
        try Control.shared.checkPaused()
        try SecurityPrompt.refuseIfShowing()
        sync()
        func f(_ n: UInt32) -> CGEventField { CGEventField(rawValue: n)! }
        func pressure(phase: Int64, stage: Int64, _ p: Double, transition: Double = 0) {
            guard let e = CGEvent(source: src) else { return }
            e.type = CGEventType(rawValue: 29)!
            e.location = pos
            e.setIntegerValueField(f(110), value: 32)
            e.setIntegerValueField(f(132), value: phase)
            e.setIntegerValueField(f(143), value: stage)
            e.setIntegerValueField(f(144), value: 5)
            for n: UInt32 in [148, 119, 139] { e.setDoubleValueField(f(n), value: p) }
            for n: UInt32 in [123, 165] { e.setIntegerValueField(f(n), value: Int64(Float(p).bitPattern)) }
            if transition != 0 {
                for n: UInt32 in [147, 113, 114, 116, 118, 142] { e.setDoubleValueField(f(n), value: transition) }
                for n: UInt32 in [115, 117, 164] { e.setIntegerValueField(f(n), value: Int64(Float(transition).bitPattern)) }
            }
            e.flags = modFlags
            post(e)
            usleep(8_000)
        }
        func button(_ type: CGEventType, _ pressureValue: Double) {
            guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pos, mouseButton: .left) else { return }
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.setIntegerValueField(.mouseEventSubtype, value: 3)  // kCGEventMouseSubtypeTouch, as a trackpad sends
            e.setDoubleValueField(.mouseEventPressure, value: pressureValue)
            e.flags = modFlags
            post(e)
        }
        pressure(phase: 1, stage: 1, 0)                          // began
        usleep(22_000)
        button(.leftMouseDown, 1)
        lock.withLock { if !heldButtons.contains(.left) { heldButtons.append(.left) } }
        for i in 1...16 {                                        // stage 1 ramp
            let p = 0.43 * Double(i) / 16
            pressure(phase: 2, stage: 1, p, transition: p > 0.3 ? (p - 0.3) : 0)
        }
        let n = max(4, Int(stage2Ms / 8))
        for i in 0..<n {                                         // stage 2: the force click
            try Control.shared.checkPaused()
            let t = Double(i) / Double(n - 1)
            pressure(phase: 2, stage: 2, 0.7 * (1 - (1 - t) * (1 - t)))
        }
        for i in 0..<6 {                                         // letting go: back to stage 1
            pressure(phase: 2, stage: 1, 1 - 0.01 * Double(i), transition: 0.44 - 0.012 * Double(i))
        }
        pressure(phase: 4, stage: 0, 0)                          // ended
        usleep(42_000)
        button(.leftMouseUp, 0)
        lock.withLock { heldButtons.removeAll { $0 == .left } }
    }

    /// Scroll wheel. Deltas follow CGEvent: positive dy = wheel up / content moves down,
    /// positive dx = content moves right. With [phased], posts trackpad-style began/changed/ended.
    func scroll(dx: Double, dy: Double, pixel: Bool, phased: Bool, steps: Int, intervalMs: Double) throws {
        try Control.shared.checkPaused()
        try SecurityPrompt.refuseIfShowing()
        sync()
        let units: CGScrollEventUnit = pixel ? .pixel : .line
        let n = phased ? max(2, steps) : max(1, steps)
        let xs = integerSplit(dx, steps: n), ys = integerSplit(dy, steps: n)
        func wheel(_ x: Double, _ y: Double, phase: Int64?) {
            guard let e = CGEvent(scrollWheelEvent2Source: src, units: units, wheelCount: 2,
                                  wheel1: Int32(y), wheel2: Int32(x), wheel3: 0) else { return }
            if let phase {
                e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            }
            e.location = pos
            e.flags = modFlags
            post(e)
        }
        for i in 0..<n {
            try Control.shared.checkPaused()
            wheel(xs[i], ys[i], phase: phased ? (i == 0 ? 1 : 2) : nil)  // kCGScrollPhaseBegan / Changed
            sleepMs(intervalMs)
        }
        if phased { wheel(0, 0, phase: 4) }  // kCGScrollPhaseEnded
    }

    // MARK: Keyboard
    //
    // Sequences come from KeyFlags (KeywrightCore): one flagsChanged per modifier with the
    // cumulative flags, key events carrying every held modifier (+ NumericPad / SecondaryFn where
    // hardware sets them), releases in reverse order.

    private func postKey(_ k: SynthKey, text: String? = nil) {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: k.keyCode, keyDown: k.kind != .keyUp) else { return }
        if k.kind == .flagsChanged { e.type = .flagsChanged }
        e.flags = CGEventFlags(rawValue: k.flags)
        if let text {
            let u = Array(text.utf16)
            e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
        }
        post(e)
    }

    /// Presses the modifiers not already held, in order, and leaves them held.
    func pressModifiers(_ mods: [KeyMap.Modifier]) throws {
        try Control.shared.checkPaused()
        try SecurityPrompt.refuseIfShowing()
        let events = lock.withLock { () -> [SynthKey] in
            let (ev, now) = KeyFlags.press(mods, held: heldMods)
            heldMods = now
            return ev
        }
        for e in events { postKey(e); usleep(8000) }
    }

    /// Releases the given held modifiers in reverse order; each release drops its flag.
    func releaseModifiers(_ mods: [KeyMap.Modifier]) {
        let events = lock.withLock { () -> [SynthKey] in
            let (ev, now) = KeyFlags.release(mods, held: heldMods)
            heldMods = now
            return ev
        }
        for e in events { postKey(e); usleep(8000) }
    }

    private func keyFlagsNow(_ code: CGKeyCode) -> UInt64 {
        lock.withLock { KeyFlags.flags(held: heldMods) } | KeyFlags.keyFlags(code)
    }

    func keyDown(_ code: CGKeyCode, text: String? = nil, layoutText: Bool = false) throws {
        try Control.shared.checkPaused()
        try SecurityPrompt.refuseIfShowing()
        lock.withLock { if !heldKeys.contains(code) { heldKeys.append(code) } }
        let flags = keyFlagsNow(code)
        postKey(SynthKey(.keyDown, code, flags), text: text ?? (layoutText ? LayoutText.text(keyCode: code, flags: flags) : nil))
    }

    func keyUp(_ code: CGKeyCode, text: String? = nil, layoutText: Bool = false) {
        lock.withLock { heldKeys.removeAll { $0 == code } }
        let flags = keyFlagsNow(code)
        postKey(SynthKey(.keyUp, code, flags), text: text ?? (layoutText ? LayoutText.text(keyCode: code, flags: flags) : nil))
    }

    /// [layoutText]: put the current layout's text for the key on its events, as hardware does.
    func key(_ code: CGKeyCode, mods: [KeyMap.Modifier], holdMs: Double, layoutText: Bool = true) throws {
        try pressModifiers(mods)
        defer { releaseModifiers(mods) }
        try keyDown(code, layoutText: layoutText)
        sleepMs(max(holdMs, 20))
        keyUp(code, layoutText: layoutText)
        usleep(5000)
    }

    /// Types [text] one character at a time. ASCII uses its US keycode (so keycode readers see a
    /// real key), with a real Shift press around uppercase letters and shifted symbols; every event
    /// also carries the character as its Unicode string, so the result does not depend on the
    /// active keyboard layout. Anything else goes through the Unicode string on keycode 0.
    func type(_ text: String, intervalMs: Double) throws {
        for ch in text {
            try Control.shared.checkPaused()
            let key = KeyMap.usKey(for: ch)
            let code = key?.code ?? 0
            let needShift = key?.shift == true && !lock.withLock({ heldMods.contains(.shift) })
            if needShift { try pressModifiers([.shift]) }
            // CGEventKeyboardSetUnicodeString takes at most 20 UTF-16 units per event.
            let units = Array(String(ch).utf16)
            var start = 0
            while start < units.count {
                let n = min(20, units.count - start)
                let chunk = String(utf16CodeUnits: Array(units[start..<start + n]), count: n)
                let text = (ch == "\n" || ch == "\r") ? "\r" : chunk
                try keyDown(code, text: text)
                keyUp(code, text: text)
                start += 20
            }
            if needShift { releaseModifiers([.shift]) }
            sleepMs(max(intervalMs, 1))
        }
    }

    // MARK: Safety

    /// Releases every button, key and modifier Keywright is holding.
    func releaseAll() {
        let (buttons, keys, mods) = lock.withLock { (heldButtons, heldKeys, heldMods) }
        for b in buttons.reversed() { up(b) }
        for k in keys.reversed() { keyUp(k) }
        releaseModifiers(mods)
    }

    var held: [String: Any] {
        lock.withLock {
            ["buttons": heldButtons.map(\.rawValue), "keys": heldKeys.map { Int($0) }, "modifiers": heldMods.map(\.rawValue)]
        }
    }
}
