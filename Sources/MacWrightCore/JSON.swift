// Tool argument access and JSON result building on top of the MCP SDK's Value.
import CoreGraphics
import Foundation
import MCP

public struct ToolError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// Sleep time in ms, clamped to 0...600 000 (NaN counts as 0).
public func clampedSleepMs(_ ms: Double) -> Double {
    ms.isNaN ? 0 : min(600_000, max(0, ms))
}

/// Sleeps `ms` milliseconds (clamped, see clampedSleepMs) without ever trapping on the
/// conversion to usleep's microseconds.
public func sleepMs(_ ms: Double) {
    var left = clampedSleepMs(ms)
    while left > 0 {
        let chunk = min(left, 1000)
        usleep(useconds_t(chunk * 1000))
        left -= chunk
    }
}

/// Typed access to a tool call's arguments, with readable errors for missing or mistyped ones.
public struct Args {
    public let raw: [String: Value]
    public init(_ raw: [String: Value]?) { self.raw = raw ?? [:] }

    public func has(_ k: String) -> Bool {
        if let v = raw[k], v != .null { return true }
        return false
    }

    /// Largest magnitude accepted for a number: enough for any coordinate, duration or id, and
    /// small enough that converting it (Int, UInt32 microseconds after clamping) can't trap.
    public static let maxNumber = 1e12

    public func double(_ k: String) throws -> Double? {
        let d: Double
        switch raw[k] {
        case nil, .null?: return nil
        case .int(let i)?: d = Double(i)
        case .double(let x)?: d = x
        case .string(let s)?:
            guard let x = Double(s) else { throw ToolError("'\(k)' must be a number") }
            d = x
        default: throw ToolError("'\(k)' must be a number")
        }
        guard d.isFinite, abs(d) <= Self.maxNumber else { throw ToolError("'\(k)' must be a finite number no larger than 1e12") }
        return d
    }
    public func double(_ k: String, _ def: Double) throws -> Double { try double(k) ?? def }
    public func req(_ k: String) throws -> Double {
        guard let v = try double(k) else { throw ToolError("missing '\(k)'") }
        return v
    }
    public func int(_ k: String) throws -> Int? { try double(k).map { Int($0) } }
    public func int(_ k: String, _ def: Int) throws -> Int { try int(k) ?? def }

    public func string(_ k: String) throws -> String? {
        switch raw[k] {
        case nil, .null?: return nil
        case .string(let s)?: return s
        case .int(let i)?: return String(i)
        case .double(let d)?: return String(d)
        default: throw ToolError("'\(k)' must be a string")
        }
    }
    public func reqString(_ k: String) throws -> String {
        guard let v = try string(k) else { throw ToolError("missing '\(k)'") }
        return v
    }

    public func bool(_ k: String, _ def: Bool) throws -> Bool {
        switch raw[k] {
        case nil, .null?: return def
        case .bool(let b)?: return b
        case .string(let s)?: return ["true", "1", "yes"].contains(s.lowercased())
        case .int(let i)?: return i != 0
        default: throw ToolError("'\(k)' must be a boolean")
        }
    }

    public func strings(_ k: String) throws -> [String]? {
        switch raw[k] {
        case nil, .null?: return nil
        case .array(let a)?: return try a.map {
            guard case .string(let s) = $0 else { throw ToolError("'\(k)' must be an array of strings") }
            return s
        }
        // Tolerate "cmd+shift" or a single name.
        case .string(let s)?: return s.split(whereSeparator: { $0 == "+" || $0 == "," || $0 == " " }).map(String.init)
        default: throw ToolError("'\(k)' must be an array of strings")
        }
    }

    public func object(_ k: String) throws -> Args? {
        switch raw[k] {
        case nil, .null?: return nil
        case .object(let o)?: return Args(o)
        default: throw ToolError("'\(k)' must be an object")
        }
    }

    public func ints(_ k: String) throws -> [Int]? {
        switch raw[k] {
        case nil, .null?: return nil
        case .array(let a)?: return try a.map {
            switch $0 {
            case .int(let i): return i
            case .double(let d): return Int(d)
            default: throw ToolError("'\(k)' must be an array of integers")
            }
        }
        case .string(let s)?:
            // "0/2/1" or "0.2.1"
            return try s.split(whereSeparator: { $0 == "/" || $0 == "." || $0 == "," }).map {
                guard let i = Int($0) else { throw ToolError("'\(k)' must be an index path like [0,2,1]") }
                return i
            }
        default: throw ToolError("'\(k)' must be an array of integers")
        }
    }
}

/// Converts plain Swift values (dictionaries, arrays, numbers, strings, CGPoint/CGRect, nil) to Value.
public func toValue(_ any: Any?) -> Value {
    guard let any else { return .null }
    switch any {
    case let v as Value: return v
    case is NSNull: return .null
    case let b as Bool: return .bool(b)
    case let i as Int: return .int(i)
    case let i as Int32: return .int(Int(i))
    case let i as Int64: return .int(Int(i))
    case let i as UInt32: return .int(Int(i))
    case let i as UInt16: return .int(Int(i))
    case let d as Double: return d.isFinite ? (d == d.rounded() && abs(d) < 1e15 ? .int(Int(d)) : .double(d)) : .null
    case let d as CGFloat: return toValue(Double(d))
    case let f as Float: return toValue(Double(f))
    case let s as String: return .string(s)
    case let p as CGPoint: return .object(["x": toValue(p.x), "y": toValue(p.y)])
    case let s as CGSize: return .object(["width": toValue(s.width), "height": toValue(s.height)])
    case let r as CGRect: return .object(["x": toValue(r.minX), "y": toValue(r.minY), "width": toValue(r.width), "height": toValue(r.height)])
    case let a as [Any?]: return .array(a.map(toValue))
    case let a as [Any]: return .array(a.map(toValue))
    case let d as [String: Any?]: return .object(d.mapValues(toValue))
    case let d as [String: Any]: return .object(d.mapValues(toValue))
    default:
        let m = Mirror(reflecting: any)
        if m.displayStyle == .optional { return m.children.first.map { toValue($0.value) } ?? .null }
        return .string(String(describing: any))
    }
}

/// Serializes a Value as compact, key-sorted JSON text.
public func jsonText(_ v: Value) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? enc.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
}

/// JSON-schema helpers for tool definitions.
public enum Schema {
    public static func object(_ props: [String: Value], required: [String] = []) -> Value {
        var o: [String: Value] = ["type": "object", "properties": .object(props)]
        if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
        return .object(o)
    }
    public static func num(_ d: String) -> Value { ["type": "number", "description": .string(d)] }
    public static func int(_ d: String) -> Value { ["type": "integer", "description": .string(d)] }
    public static func str(_ d: String) -> Value { ["type": "string", "description": .string(d)] }
    public static func bool(_ d: String) -> Value { ["type": "boolean", "description": .string(d)] }
    public static func `enum`(_ cases: [String], _ d: String) -> Value {
        ["type": "string", "enum": .array(cases.map { .string($0) }), "description": .string(d)]
    }
    public static func strs(_ d: String) -> Value { ["type": "array", "items": ["type": "string"], "description": .string(d)] }
    public static func ints(_ d: String) -> Value { ["type": "array", "items": ["type": "integer"], "description": .string(d)] }
    public static func obj(_ d: String) -> Value { ["type": "object", "description": .string(d)] }
}
