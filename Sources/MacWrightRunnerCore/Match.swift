// Result paths, matchers and ${var} interpolation for macwright-run.
import Foundation
import MCP

/// A path into a tool result: `windows[0].title`, `cursor.hidden`, `items.2.name`.
public struct Path: Equatable {
    public enum Part: Equatable { case key(String), index(Int) }
    public var parts: [Part]

    public static func parse(_ s: String) throws -> Path {
        var parts: [Part] = []
        var cur = ""
        var i = s.startIndex
        func flush() { if !cur.isEmpty { parts.append(Int(cur).map(Part.index) ?? .key(cur)); cur = "" } }
        while i < s.endIndex {
            let c = s[i]
            if c == "." { flush() }
            else if c == "[" {
                flush()
                guard let close = s[i...].firstIndex(of: "]"), let n = Int(s[s.index(after: i)..<close]) else {
                    throw SpecError("bad result path `\(s)`: `[` needs a number and `]`")
                }
                parts.append(.index(n))
                i = close
            } else { cur.append(c) }
            i = s.index(after: i)
        }
        flush()
        if parts.isEmpty { throw SpecError("empty result path") }
        return Path(parts: parts)
    }

    /// The value at this path, or nil when it isn't there. A negative index counts from the end.
    public func resolve(_ v: Value) -> Value? {
        var cur = v
        for p in parts {
            switch (p, cur) {
            case (.key(let k), .object(let o)): guard let n = o[k] else { return nil }; cur = n
            case (.index(let n), .array(let a)):
                let i = n < 0 ? a.count + n : n
                guard a.indices.contains(i) else { return nil }
                cur = a[i]
            case (.index(let n), .object(let o)): guard let x = o[String(n)] else { return nil }; cur = x
            default: return nil
            }
        }
        return cur
    }
}

/// Matchers. A literal (string, number, bool, null, list) must equal the value; a literal map must
/// match as a subset (every key given matches, other keys are ignored). A map whose keys are all
/// operators is an operator matcher:
/// equals, not, contains, matches (regex), gt, gte, lt, lte, exists (bool), length (number or matcher),
/// any (list of matchers, one must pass), all (list of matchers).
public enum Match {
    static let ops: Set<String> = ["equals", "not", "contains", "matches", "gt", "gte", "lt", "lte", "exists", "length", "any", "all"]

    static func isOperatorMap(_ m: Value) -> [String: Value]? {
        guard case .object(let o) = m, !o.isEmpty, o.keys.allSatisfy(ops.contains) else { return nil }
        return o
    }

    public static func validate(_ m: Value, at: String) throws {
        guard let o = isOperatorMap(m) else { return }
        if let r = o["matches"] {
            guard case .string(let p) = r, (try? NSRegularExpression(pattern: p)) != nil else {
                throw SpecError("\(at): `matches` needs a valid regular expression")
            }
        }
        for k in ["gt", "gte", "lt", "lte"] where o[k] != nil {
            if number(o[k]!) == nil, !isVar(o[k]!) { throw SpecError("\(at): `\(k)` needs a number") }
        }
        for k in ["any", "all"] where o[k] != nil {
            guard case .array(let a) = o[k]! else { throw SpecError("\(at): `\(k)` needs a list of matchers") }
            for x in a { try validate(x, at: at) }
        }
        if let n = o["not"] { try validate(n, at: at) }
        if let n = o["length"] { try validate(n, at: at) }
    }

    static func isVar(_ v: Value) -> Bool { if case .string(let s) = v { return s.contains("${") }; return false }

    /// nil when `actual` passes, else why it didn't. `actual` is nil when the path is missing.
    public static func check(_ m: Value, _ actual: Value?) -> String? {
        guard let o = isOperatorMap(m) else {
            guard let actual else { return "missing (expected \(show(m)))" }
            return subset(m, actual) ? nil : "expected \(show(m)), got \(show(actual))"
        }
        for k in o.keys.sorted() {
            if let why = op(k, o[k]!, actual) { return why }
        }
        return nil
    }

    static func op(_ k: String, _ arg: Value, _ actual: Value?) -> String? {
        if k == "exists" {
            let want = arg.boolValue ?? true
            return (actual != nil) == want ? nil : (want ? "missing" : "expected it to be missing, got \(show(actual!))")
        }
        if k == "not" {
            return check(arg, actual) == nil ? "expected not \(show(arg)), got \(actual.map(show) ?? "missing")" : nil
        }
        if k == "any" {
            let ms = arg.arrayValue ?? []
            return ms.contains { check($0, actual) == nil } ? nil : "none of \(show(arg)) matched \(actual.map(show) ?? "missing")"
        }
        if k == "all" {
            for x in arg.arrayValue ?? [] { if let why = check(x, actual) { return why } }
            return nil
        }
        guard let actual else { return "missing" }
        switch k {
        case "equals":
            return equal(arg, actual) ? nil : "expected \(show(arg)), got \(show(actual))"
        case "contains":
            switch actual {
            case .string(let s):
                guard case .string(let sub) = arg else { return "contains on a string needs a string" }
                return s.contains(sub) ? nil : "expected \(show(actual)) to contain \(show(arg))"
            case .array(let a):
                return a.contains { subset(arg, $0) } ? nil : "no element of \(show(actual)) matches \(show(arg))"
            case .object(let o):
                guard case .string(let key) = arg else { return "contains on a map needs a key" }
                return o[key] != nil ? nil : "expected key \(show(arg)) in \(show(actual))"
            default: return "contains needs a string, list or map, got \(show(actual))"
            }
        case "matches":
            guard case .string(let s) = actual else { return "expected a string matching \(show(arg)), got \(show(actual))" }
            guard case .string(let p) = arg, let re = try? NSRegularExpression(pattern: p) else { return "bad regex \(show(arg))" }
            return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil ? nil : "expected \(show(actual)) to match /\(p)/"
        case "gt", "gte", "lt", "lte":
            guard let a = number(actual), let b = number(arg) else { return "expected a number, got \(show(actual))" }
            let ok = k == "gt" ? a > b : k == "gte" ? a >= b : k == "lt" ? a < b : a <= b
            let sym = ["gt": ">", "gte": ">=", "lt": "<", "lte": "<="][k]!
            return ok ? nil : "expected \(show(actual)) \(sym) \(show(arg))"
        case "length":
            let n: Int
            switch actual {
            case .array(let a): n = a.count
            case .string(let s): n = s.count
            case .object(let o): n = o.count
            default: return "length needs a list, string or map, got \(show(actual))"
            }
            return check(arg, .int(n)).map { "length \(n): \($0)" }
        default: return "unknown matcher \(k)"
        }
    }

    static func number(_ v: Value) -> Double? {
        switch v {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    /// Exact equality, with 1 == 1.0.
    public static func equal(_ a: Value, _ b: Value) -> Bool {
        if let x = number(a), let y = number(b) { return x == y }
        switch (a, b) {
        case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
        case (.object(let x), .object(let y)): return x.count == y.count && x.allSatisfy { k, v in y[k].map { equal(v, $0) } ?? false }
        default: return a == b
        }
    }

    /// Like equal, but a map only needs the keys it names (recursively), and a map value may be a matcher.
    public static func subset(_ expected: Value, _ actual: Value) -> Bool {
        if isOperatorMap(expected) != nil { return check(expected, actual) == nil }
        switch (expected, actual) {
        case (.object(let e), .object(let a)):
            return e.allSatisfy { k, v in a[k].map { subset(v, $0) } ?? false }
        case (.array(let e), .array(let a)):
            return e.count == a.count && zip(e, a).allSatisfy { subset($0, $1) }
        default: return equal(expected, actual)
        }
    }

    public static func show(_ v: Value) -> String {
        let s = jsonString(v)
        return s.count > 160 ? String(s.prefix(157)) + "…" : s
    }
}

public func jsonString(_ v: Value, pretty: Bool = false) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
    return (try? enc.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? "\(v)"
}

/// `${name}` and `${env.NAME}` in strings. A string that is exactly one `${…}` takes the variable's
/// value with its type (a number stays a number); inside a longer string the value is spliced in as text.
public enum Interpolate {
    public static func apply(_ v: Value, vars: [String: Value], env: [String: String]) throws -> Value {
        switch v {
        case .string(let s): return try string(s, vars: vars, env: env)
        case .array(let a): return .array(try a.map { try apply($0, vars: vars, env: env) })
        case .object(let o): return .object(try o.mapValues { try apply($0, vars: vars, env: env) })
        default: return v
        }
    }

    static func lookup(_ name: String, vars: [String: Value], env: [String: String]) throws -> Value {
        if name.hasPrefix("env.") {
            let key = String(name.dropFirst(4))
            guard let e = env[key] else { throw SpecError("environment variable \(key) is not set") }
            return .string(e)
        }
        // `${win.id}` reads into a saved map or list.
        let head = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
        let headKey = head.split(separator: "[", maxSplits: 1).first.map(String.init) ?? head
        guard let base = vars[headKey] else { throw SpecError("unknown variable \(name)") }
        if headKey == name { return base }
        let rest = String(name.dropFirst(headKey.count)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let v = try Path.parse(rest).resolve(base) else { throw SpecError("variable \(name) has no such field") }
        return v
    }

    static func string(_ s: String, vars: [String: Value], env: [String: String]) throws -> Value {
        guard s.contains("${") else { return .string(s) }
        if s.hasPrefix("${"), s.hasSuffix("}"), s.firstIndex(of: "}") == s.index(before: s.endIndex) {
            return try lookup(String(s.dropFirst(2).dropLast()), vars: vars, env: env)
        }
        var out = ""
        var rest = Substring(s)
        while let open = rest.range(of: "${") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else { throw SpecError("unclosed ${ in \"\(s)\"") }
            let v = try lookup(String(rest[open.upperBound..<close]), vars: vars, env: env)
            if case .string(let t) = v { out += t } else { out += jsonString(v) }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return .string(out)
    }
}
