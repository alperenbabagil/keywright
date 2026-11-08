// Key names → macOS virtual keycodes (ANSI positions, kVK_* in Carbon's Events.h).
import CoreGraphics
import Foundation

public enum KeyMapError: Error, CustomStringConvertible {
    case unknownKey(String)
    case unknownModifier(String)
    public var description: String {
        switch self {
        case .unknownKey(let k): return "unknown key '\(k)' (use a name like esc, return, a, f5, left, or a raw keycode such as 53 / 0x35)"
        case .unknownModifier(let m): return "unknown modifier '\(m)' (use cmd, opt, ctrl, shift, fn)"
        }
    }
}

public enum KeyMap {
    public static let names: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
            "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
            "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
            "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
            "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
            "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
            "return": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "esc": 0x35,
            "cmd": 0x37, "shift": 0x38, "capslock": 0x39, "opt": 0x3A, "ctrl": 0x3B,
            "rcmd": 0x36, "rshift": 0x3C, "ropt": 0x3D, "rctrl": 0x3E, "fn": 0x3F,
            "volumeup": 0x48, "volumedown": 0x49, "mute": 0x4A, "kpenter": 0x4C,
            "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
            "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F, "f13": 0x69, "f14": 0x6B,
            "f15": 0x71, "f16": 0x6A, "f17": 0x40, "f18": 0x4F, "f19": 0x50, "f20": 0x5A,
            "help": 0x72, "home": 0x73, "pageup": 0x74, "forwarddelete": 0x75, "end": 0x77,
            "pagedown": 0x79, "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        ]
        let aliases: [String: String] = [
            "escape": "esc", "enter": "return", "backspace": "delete", "del": "forwarddelete",
            "spacebar": "space", "command": "cmd", "option": "opt", "alt": "opt", "control": "ctrl",
            "leftarrow": "left", "rightarrow": "right", "uparrow": "up", "downarrow": "down",
            "arrowleft": "left", "arrowright": "right", "arrowup": "up", "arrowdown": "down",
            "pgup": "pageup", "pgdn": "pagedown", "minus": "-", "equal": "=", "comma": ",",
            "period": ".", "slash": "/", "backslash": "\\", "semicolon": ";", "quote": "'",
            "grave": "`", "backtick": "`", "leftbracket": "[", "rightbracket": "]",
        ]
        for (alias, target) in aliases { m[alias] = m[target] }
        return m
    }()

    /// Resolves a key name (case-insensitive) or a raw keycode ("53", "0x35", "keycode:53").
    public static func keyCode(_ name: String) throws -> CGKeyCode {
        let raw = name.count == 1 ? name.lowercased() : name.lowercased().replacingOccurrences(of: "_", with: "")
        if let code = names[raw] { return code }
        var num = raw
        if num.hasPrefix("keycode:") { num.removeFirst("keycode:".count) }
        if num.hasPrefix("0x"), let v = UInt16(num.dropFirst(2), radix: 16), v < 128 { return v }
        if let v = UInt16(num), v < 128, name.count > 1 { return v }
        throw KeyMapError.unknownKey(name)
    }

    public enum Modifier: String, CaseIterable, Sendable {
        case cmd, opt, ctrl, shift, fn
        public var flag: CGEventFlags {
            switch self {
            case .cmd: return .maskCommand
            case .opt: return .maskAlternate
            case .ctrl: return .maskControl
            case .shift: return .maskShift
            case .fn: return .maskSecondaryFn
            }
        }
        /// The left-hand modifier key, posted as a flagsChanged press around the main key.
        public var keyCode: CGKeyCode {
            switch self {
            case .cmd: return 0x37
            case .opt: return 0x3A
            case .ctrl: return 0x3B
            case .shift: return 0x38
            case .fn: return 0x3F
            }
        }
    }

    public static func modifier(_ name: String) throws -> Modifier {
        switch name.lowercased() {
        case "cmd", "command", "⌘": return .cmd
        case "opt", "option", "alt", "⌥": return .opt
        case "ctrl", "control", "⌃": return .ctrl
        case "shift", "⇧": return .shift
        case "fn", "function": return .fn
        default: throw KeyMapError.unknownModifier(name)
        }
    }

    public static func flags(_ mods: [Modifier]) -> CGEventFlags {
        mods.reduce(CGEventFlags()) { $0.union($1.flag) }
    }

    /// Keycode + shift for a character on the US ANSI layout, used so plain ASCII typing produces
    /// real keycodes (apps that read keycodes see what a keyboard would send). nil → Unicode-only.
    public static func usKey(for ch: Character) -> (code: CGKeyCode, shift: Bool)? {
        let shifted: [Character: Character] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
            ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'",
            "<": ",", ">": ".", "?": "/", "~": "`",
        ]
        if ch == " " { return (0x31, false) }
        if ch == "\n" || ch == "\r" { return (0x24, false) }
        if ch == "\t" { return (0x30, false) }
        guard ch.isASCII else { return nil }
        if ch.isUppercase, let code = names[String(ch).lowercased()] { return (code, true) }
        if let base = shifted[ch], let code = names[String(base)] { return (code, true) }
        if let code = names[String(ch)] { return (code, false) }
        return nil
    }
}
