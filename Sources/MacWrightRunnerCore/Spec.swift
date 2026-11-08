// Test files for macwright-run: YAML (or JSON, which YAML reads too) with setup, steps and
// teardown. Each step is one tool call, `- tool_name: {args}`, plus optional reserved keys.
import Foundation
import MCP
import Yams

public struct SpecError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

public struct Retry: Equatable {
    public var timeoutMs: Int
    public var intervalMs: Int
}

public enum ExpectError: Equatable {
    case any
    case containing(String)
}

public struct Step {
    /// Where the step is in its file, e.g. `steps[3]`.
    public var location: String
    public var name: String?
    public var tool: String
    public var args: [String: Value]
    /// Result path → matcher (see Match.swift).
    public var expect: [(path: String, matcher: Value)]
    public var expectError: ExpectError?
    /// Variable name → result path.
    public var save: [(name: String, path: String)]
    public var retry: Retry?

    public var label: String { name ?? tool }
}

public struct TestFile {
    public var path: String
    public var name: String
    public var vars: [String: Value]
    public var setup: [Step]
    public var steps: [Step]
    public var teardown: [Step]

    public var allSteps: [Step] { setup + steps + teardown }
}

public enum Spec {
    static let stepKeys: Set<String> = ["name", "expect", "expectError", "save", "retry"]
    static let fileKeys: Set<String> = ["name", "vars", "setup", "steps", "teardown"]

    public static func load(path: String) throws -> TestFile {
        let text: String
        do { text = try String(contentsOfFile: path, encoding: .utf8) } catch {
            throw SpecError("\(path): can't read (\(error.localizedDescription))")
        }
        do { return try parse(text, path: path) } catch let e as SpecError {
            throw SpecError("\(path): \(e.description)")
        }
    }

    public static func parse(_ text: String, path: String = "<inline>") throws -> TestFile {
        let raw: Any?
        do { raw = try Yams.load(yaml: text) } catch { throw SpecError("not valid YAML/JSON: \(error)") }
        guard case .object(let root)? = raw.map(toValue) else { throw SpecError("the top level must be a map with `steps`") }
        if let unknown = root.keys.first(where: { !fileKeys.contains($0) }) {
            throw SpecError("unknown key `\(unknown)` (expected \(fileKeys.sorted().joined(separator: ", ")))")
        }
        let defaultName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var vars: [String: Value] = [:]
        if let v = root["vars"] {
            guard case .object(let o) = v else { throw SpecError("`vars` must be a map") }
            vars = o
        }
        guard root["steps"] != nil else { throw SpecError("missing `steps`") }
        return TestFile(path: path, name: root["name"]?.stringValue ?? defaultName, vars: vars,
                        setup: try steps(root["setup"], "setup"), steps: try steps(root["steps"], "steps"),
                        teardown: try steps(root["teardown"], "teardown"))
    }

    static func steps(_ v: Value?, _ section: String) throws -> [Step] {
        guard let v, v != .null else { return [] }
        guard case .array(let items) = v else { throw SpecError("`\(section)` must be a list of steps") }
        return try items.enumerated().map { try step($1, "\(section)[\($0)]") }
    }

    static func step(_ v: Value, _ loc: String) throws -> Step {
        // A bare string is a call with no arguments: `- release_all`.
        if case .string(let tool) = v { return Step(location: loc, tool: tool, args: [:], expect: [], save: []) }
        guard case .object(let o) = v else { throw SpecError("\(loc): a step is `- tool: {args}`") }
        let tools = o.keys.filter { !stepKeys.contains($0) }
        guard tools.count == 1, let tool = tools.first else {
            throw SpecError(tools.isEmpty ? "\(loc): no tool in this step"
                                          : "\(loc): one tool per step, found \(tools.sorted().joined(separator: ", "))")
        }
        var args: [String: Value] = [:]
        switch o[tool] {
        case .object(let a)?: args = a
        case .null?, nil: break
        default: throw SpecError("\(loc): the arguments of `\(tool)` must be a map")
        }
        var step = Step(location: loc, name: o["name"]?.stringValue, tool: tool, args: args, expect: [], save: [])
        if let e = o["expect"] {
            guard case .object(let m) = e else { throw SpecError("\(loc): `expect` must map result paths to matchers") }
            for k in m.keys.sorted() { _ = try Path.parse(k); try Match.validate(m[k]!, at: "\(loc).expect.\(k)") }
            step.expect = m.keys.sorted().map { ($0, m[$0]!) }
        }
        switch o["expectError"] {
        case nil, .null?, .bool(false)?: break
        case .bool(true)?: step.expectError = .any
        case .string(let s)?: step.expectError = .containing(s)
        default: throw SpecError("\(loc): `expectError` is true or a message substring")
        }
        if let s = o["save"] {
            guard case .object(let m) = s else { throw SpecError("\(loc): `save` maps variable names to result paths") }
            step.save = try m.keys.sorted().map { k in
                guard case .string(let p) = m[k]! else { throw SpecError("\(loc): save.\(k) must be a result path") }
                _ = try Path.parse(p)
                return (k, p)
            }
        }
        switch o["retry"] {
        case nil, .null?: break
        case .int(let ms)?: step.retry = Retry(timeoutMs: ms, intervalMs: 250)
        case .object(let r)?:
            guard let t = r["timeoutMs"]?.intValue else { throw SpecError("\(loc): retry needs timeoutMs") }
            step.retry = Retry(timeoutMs: t, intervalMs: r["intervalMs"]?.intValue ?? 250)
        default: throw SpecError("\(loc): `retry` is a timeout in ms or {timeoutMs, intervalMs}")
        }
        if step.retry != nil && step.expect.isEmpty && step.expectError == nil {
            throw SpecError("\(loc): `retry` repeats the call until `expect` passes, so it needs `expect`")
        }
        return step
    }

    /// Yams' native output (dictionaries, arrays, Int, Double, Bool, String, NSNull) → Value.
    static func toValue(_ any: Any) -> Value {
        switch any {
        case let b as Bool: return .bool(b)
        case let i as Int: return .int(i)
        case let d as Double: return .double(d)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map(toValue))
        case let m as [String: Any]: return .object(m.mapValues(toValue))
        case let m as [AnyHashable: Any]:
            return .object(Dictionary(m.map { ("\($0.key)", toValue($0.value)) }, uniquingKeysWith: { a, _ in a }))
        case let d as Date: return .string(ISO8601DateFormatter().string(from: d))
        case let d as Data: return .string(d.base64EncodedString())
        default: return .null
        }
    }

    /// Every test file under the given files and folders (.yml, .yaml, .json), sorted per folder.
    public static func collect(_ paths: [String]) throws -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for p in paths {
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &dir) else { throw SpecError("\(p): no such file or folder") }
            if !dir.boolValue { out.append(p); continue }
            let found = (fm.enumerator(atPath: p)?.allObjects as? [String] ?? [])
                .filter { ["yml", "yaml", "json"].contains(($0 as NSString).pathExtension.lowercased()) }
                .sorted()
                .map { (p as NSString).appendingPathComponent($0) }
            out += found
        }
        return out
    }
}
