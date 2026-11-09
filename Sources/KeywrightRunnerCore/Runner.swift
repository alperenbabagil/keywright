// Runs test files against anything that can call Keywright's tools.
import Foundation
import MCP

public struct ToolResult {
    public var json: Value
    public var isError: Bool
    public init(json: Value, isError: Bool) { self.json = json; self.isError = isError }

    public var errorMessage: String {
        if case .object(let o) = json, case .string(let e)? = o["error"] { return e }
        return Match.show(json)
    }
}

public protocol ToolCaller {
    func call(_ tool: String, _ args: [String: Value]) async throws -> ToolResult
}

public struct StepResult {
    public enum Status: String { case passed, failed, skipped }
    public var step: Step
    public var section: String
    public var status: Status
    public var ms: Int
    public var message: String?
    public var attempts: Int
    public var result: Value?
}

public struct TestResult {
    public var file: TestFile
    public var steps: [StepResult]
    public var ms: Int
    public var artifacts: [String]
    public var passed: Bool { !steps.contains { $0.status == .failed } }
    public var failure: StepResult? { steps.first { $0.status == .failed } }
}

public protocol RunObserver {
    func testStarted(_ file: TestFile)
    func stepFinished(_ r: StepResult)
    func testFinished(_ r: TestResult)
}

public struct Runner {
    public var caller: ToolCaller
    public var vars: [String: Value]
    public var env: [String: String]
    /// Called once when a test fails (before teardown); returns artifact paths, e.g. a screenshot.
    public var onFailure: ((TestFile, StepResult) async -> [String])?
    public var observer: RunObserver?
    public var sleep: (Int) async -> Void = { ms in try? await Task.sleep(nanoseconds: UInt64(max(ms, 0)) * 1_000_000) }

    public init(caller: ToolCaller, vars: [String: Value] = [:], env: [String: String] = ProcessInfo.processInfo.environment,
                onFailure: ((TestFile, StepResult) async -> [String])? = nil, observer: RunObserver? = nil) {
        self.caller = caller; self.vars = vars; self.env = env; self.onFailure = onFailure; self.observer = observer
    }

    /// Setup and steps stop at the first failure; teardown always runs, every step of it.
    public func run(_ file: TestFile) async -> TestResult {
        observer?.testStarted(file)
        let t0 = Date()
        var vars = file.vars.merging(self.vars) { _, cli in cli }
        var results: [StepResult] = []
        var artifacts: [String] = []
        var failed = false
        for (section, steps) in [("setup", file.setup), ("steps", file.steps)] {
            for s in steps {
                if failed {
                    let r = StepResult(step: s, section: section, status: .skipped, ms: 0, attempts: 0)
                    results.append(r); observer?.stepFinished(r); continue
                }
                let r = await runStep(s, section: section, vars: &vars)
                results.append(r); observer?.stepFinished(r)
                if r.status == .failed {
                    failed = true
                    if let onFailure { artifacts += await onFailure(file, r) }
                }
            }
        }
        for s in file.teardown {
            let r = await runStep(s, section: "teardown", vars: &vars)
            results.append(r); observer?.stepFinished(r)
        }
        let tr = TestResult(file: file, steps: results, ms: Int(Date().timeIntervalSince(t0) * 1000), artifacts: artifacts)
        observer?.testFinished(tr)
        return tr
    }

    func runStep(_ s: Step, section: String, vars: inout [String: Value]) async -> StepResult {
        let t0 = Date()
        var attempts = 0
        func done(_ status: StepResult.Status, _ msg: String?, _ result: Value?) -> StepResult {
            StepResult(step: s, section: section, status: status, ms: Int(Date().timeIntervalSince(t0) * 1000),
                       message: msg, attempts: attempts, result: result)
        }
        let args: [String: Value]
        do {
            guard case .object(let a) = try Interpolate.apply(.object(s.args), vars: vars, env: env) else { return done(.failed, "bad arguments", nil) }
            args = a
        } catch { return done(.failed, "\(error)", nil) }
        let deadline = s.retry.map { t0.addingTimeInterval(Double($0.timeoutMs) / 1000) }
        while true {
            attempts += 1
            let outcome: (String?, Value?)
            do {
                let r = try await caller.call(s.tool, args)
                outcome = (try check(s, r, vars: vars), r.json)
            } catch {
                outcome = ("call failed: \(error)", nil)
            }
            if outcome.0 == nil {
                for (name, path) in s.save {
                    guard let r = outcome.1, let v = try? Path.parse(path).resolve(r) else {
                        return done(.failed, "save \(name): result has no \(path)", outcome.1)
                    }
                    vars[name] = v
                }
                return done(.passed, nil, outcome.1)
            }
            guard let deadline, let retry = s.retry, Date() < deadline else {
                let why = attempts > 1 ? "\(outcome.0!) (after \(attempts) attempts)" : outcome.0!
                return done(.failed, why, outcome.1)
            }
            await sleep(min(retry.intervalMs, max(0, Int(deadline.timeIntervalSinceNow * 1000))))
        }
    }

    /// nil when the result is what the step expects.
    func check(_ s: Step, _ r: ToolResult, vars: [String: Value]) throws -> String? {
        switch (s.expectError, r.isError) {
        case (nil, true): return r.errorMessage
        case (.some, false): return "expected an error, the call succeeded"
        case (.containing(let sub)?, true):
            if !r.errorMessage.contains(sub) { return "expected an error containing \"\(sub)\", got \"\(r.errorMessage)\"" }
        default: break
        }
        for (path, matcher) in s.expect {
            let m = try Interpolate.apply(matcher, vars: vars, env: env)
            if let why = Match.check(m, try Path.parse(path).resolve(r.json)) { return "\(path): \(why)" }
        }
        return nil
    }
}

/// JUnit XML, the format CI systems read: one testsuite per file, one testcase per step.
public enum JUnit {
    public static func xml(_ results: [TestResult]) -> String {
        func esc(_ s: String) -> String {
            var o = ""
            for ch in s.unicodeScalars {
                switch ch {
                case "&": o += "&amp;"
                case "<": o += "&lt;"
                case ">": o += "&gt;"
                case "\"": o += "&quot;"
                case "\n", "\t", "\r": o.unicodeScalars.append(ch)
                default: if ch.value >= 0x20 { o.unicodeScalars.append(ch) }
                }
            }
            return o
        }
        let tests = results.reduce(0) { $0 + $1.steps.count }
        let failures = results.reduce(0) { $0 + $1.steps.filter { $0.status == .failed }.count }
        let total = Double(results.reduce(0) { $0 + $1.ms }) / 1000
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        x += "<testsuites name=\"keywright\" tests=\"\(tests)\" failures=\"\(failures)\" time=\"\(total)\">\n"
        for r in results {
            let f = r.steps.filter { $0.status == .failed }.count
            let sk = r.steps.filter { $0.status == .skipped }.count
            x += "  <testsuite name=\"\(esc(r.file.name))\" file=\"\(esc(r.file.path))\" tests=\"\(r.steps.count)\" failures=\"\(f)\" skipped=\"\(sk)\" time=\"\(Double(r.ms) / 1000)\">\n"
            for s in r.steps {
                let name = "\(s.step.location) \(s.step.label)"
                x += "    <testcase classname=\"\(esc(r.file.name))\" name=\"\(esc(name))\" time=\"\(Double(s.ms) / 1000)\""
                switch s.status {
                case .passed: x += "/>\n"
                case .skipped: x += "><skipped/></testcase>\n"
                case .failed:
                    x += "><failure message=\"\(esc(s.message ?? "failed"))\">\(esc(s.result.map { jsonString($0, pretty: true) } ?? ""))</failure></testcase>\n"
                }
            }
            if !r.artifacts.isEmpty {
                x += "    <system-out>\(esc(r.artifacts.map { "[[ATTACHMENT|\($0)]]" }.joined(separator: "\n")))</system-out>\n"
            }
            x += "  </testsuite>\n"
        }
        return x + "</testsuites>\n"
    }
}
