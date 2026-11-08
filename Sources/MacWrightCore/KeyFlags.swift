// Modifier-flag bookkeeping for synthetic keyboard input, as pure functions over a small event
// model. The goal is events indistinguishable from a physical keyboard's: each modifier is its
// own flagsChanged press carrying the cumulative flags, every key event carries every modifier
// held at that moment (with the device-dependent left/right bits and NonCoalesced), arrows and
// function keys carry NumericPad / SecondaryFn, and modifiers are released in reverse order.
import CoreGraphics
import Foundation

public enum EventFlag {
    // Device-independent masks (CGEventFlags).
    public static let shift: UInt64 = 0x0002_0000        // kCGEventFlagMaskShift
    public static let control: UInt64 = 0x0004_0000      // kCGEventFlagMaskControl
    public static let alternate: UInt64 = 0x0008_0000    // kCGEventFlagMaskAlternate
    public static let command: UInt64 = 0x0010_0000      // kCGEventFlagMaskCommand
    public static let numericPad: UInt64 = 0x0020_0000   // kCGEventFlagMaskNumericPad
    public static let secondaryFn: UInt64 = 0x0080_0000  // kCGEventFlagMaskSecondaryFn
    public static let nonCoalesced: UInt64 = 0x0000_0100 // kCGEventFlagMaskNonCoalesced
    // Device-dependent bits a real keyboard adds (IOLLEvent.h NX_DEVICE*KEYMASK).
    public static let deviceLeftControl: UInt64 = 0x0001
    public static let deviceLeftShift: UInt64 = 0x0002
    public static let deviceRightShift: UInt64 = 0x0004
    public static let deviceLeftCommand: UInt64 = 0x0008
    public static let deviceRightCommand: UInt64 = 0x0010
    public static let deviceLeftAlternate: UInt64 = 0x0020
    public static let deviceRightAlternate: UInt64 = 0x0040
    public static let deviceRightControl: UInt64 = 0x2000

    /// Readable names for the device-independent modifier bits set in [flags].
    public static func names(_ flags: UInt64) -> [String] {
        var out: [String] = []
        if flags & command != 0 { out.append("cmd") }
        if flags & alternate != 0 { out.append("opt") }
        if flags & control != 0 { out.append("ctrl") }
        if flags & shift != 0 { out.append("shift") }
        if flags & secondaryFn != 0 { out.append("fn") }
        if flags & numericPad != 0 { out.append("numpad") }
        return out
    }
}

extension KeyMap.Modifier {
    /// The modifier's device-independent mask plus the left-hand device bit a keyboard sets.
    public var hardwareFlags: UInt64 {
        switch self {
        case .cmd: return EventFlag.command | EventFlag.deviceLeftCommand
        case .opt: return EventFlag.alternate | EventFlag.deviceLeftAlternate
        case .ctrl: return EventFlag.control | EventFlag.deviceLeftControl
        case .shift: return EventFlag.shift | EventFlag.deviceLeftShift
        case .fn: return EventFlag.secondaryFn
        }
    }
}

/// One synthetic keyboard event.
public struct SynthKey: Equatable, CustomStringConvertible {
    public enum Kind: String { case flagsChanged, keyDown, keyUp }
    public var kind: Kind
    public var keyCode: CGKeyCode
    public var flags: UInt64

    public init(_ kind: Kind, _ keyCode: CGKeyCode, _ flags: UInt64) {
        self.kind = kind; self.keyCode = keyCode; self.flags = flags
    }

    public var description: String {
        "\(kind.rawValue) 0x\(String(keyCode, radix: 16)) flags=0x\(String(flags, radix: 16))"
    }
}

public enum KeyFlags {
    /// Flags for an event while [held] modifiers are down.
    public static func flags(held: [KeyMap.Modifier]) -> UInt64 {
        held.reduce(EventFlag.nonCoalesced) { $0 | $1.hardwareFlags }
    }

    /// Extra flags the hardware puts on a key's own events: arrows carry NumericPad + SecondaryFn,
    /// keypad keys NumericPad, function and navigation keys SecondaryFn.
    public static func keyFlags(_ code: CGKeyCode) -> UInt64 {
        switch code {
        case 0x7B, 0x7C, 0x7D, 0x7E:                       // left, right, down, up
            return EventFlag.numericPad | EventFlag.secondaryFn
        case 0x41, 0x43, 0x45, 0x47, 0x4B, 0x4C, 0x4E, 0x51, 0x52...0x59, 0x5B, 0x5C:  // keypad
            return EventFlag.numericPad
        case 0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,  // F1-F12
             0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,                          // F13-F20
             0x72, 0x73, 0x74, 0x75, 0x77, 0x79:                                      // help, home, pgup, fwd-del, end, pgdn
            return EventFlag.secondaryFn
        default:
            return 0
        }
    }

    /// flagsChanged presses for the modifiers in [add] that are not already held, in order.
    /// Returns the events and the new held list.
    public static func press(_ add: [KeyMap.Modifier], held: [KeyMap.Modifier]) -> ([SynthKey], [KeyMap.Modifier]) {
        var now = held
        var out: [SynthKey] = []
        for m in add where !now.contains(m) {
            now.append(m)
            out.append(SynthKey(.flagsChanged, m.keyCode, flags(held: now)))
        }
        return (out, now)
    }

    /// flagsChanged releases for [remove] (those actually held), in reverse order; each event's
    /// flags no longer include the modifier being released.
    public static func release(_ remove: [KeyMap.Modifier], held: [KeyMap.Modifier]) -> ([SynthKey], [KeyMap.Modifier]) {
        var now = held
        var out: [SynthKey] = []
        for m in remove.reversed() where now.contains(m) {
            now.removeAll { $0 == m }
            out.append(SynthKey(.flagsChanged, m.keyCode, flags(held: now)))
        }
        return (out, now)
    }

    /// Down and up for [code] while [held] modifiers are down.
    public static func stroke(_ code: CGKeyCode, held: [KeyMap.Modifier]) -> [SynthKey] {
        let f = flags(held: held) | keyFlags(code)
        return [SynthKey(.keyDown, code, f), SynthKey(.keyUp, code, f)]
    }

    /// The full physical sequence for a chord: modifier presses, the key, reverse releases.
    public static func chord(_ code: CGKeyCode, mods: [KeyMap.Modifier], held: [KeyMap.Modifier] = []) -> [SynthKey] {
        let (down, during) = press(mods, held: held)
        let (up, _) = release(mods.filter { !held.contains($0) }, held: during)
        return down + stroke(code, held: during) + up
    }
}
