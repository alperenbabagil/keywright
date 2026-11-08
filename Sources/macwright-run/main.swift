// macwright-run: runs YAML/JSON test files against a running, unlocked MacWright over MCP.
// It has no permissions of its own: every step is a tool call with the bearer token, the same
// as any MCP client.
import Foundation
import MacWrightRunnerCore
import MCP

let usage = """
    Usage: macwright-run [options] <file-or-folder>...

    Runs MacWright test files (.yml, .yaml, .json) against the MacWright app, which must be running
    and unlocked. Exit status: 0 all passed, 1 a test failed, 2 usage or connection error.

    Options:
      --token <token>      Bearer token (default: $MACWRIGHT_TOKEN, preferred: ps shows arguments).
                           Menu: Token → Copy token.
      --server <url>       MCP endpoint (default: $MACWRIGHT_SERVER, or 127.0.0.1 on the app's port)
      --var <name>=<value> Set a variable for ${name}; repeatable, overrides the file's vars
      --junit <path>       Write a JUnit XML report
      --artifacts <dir>    On a failure, save a screenshot of the main display there
      --fail-fast          Stop after the first failing test
      --check              Parse the files (and check tool names, if a token is given), run nothing
      --verbose            Print every step's result
      -h, --help           Show this help
    """

func fail(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("macwright-run: \(msg)\n".utf8))
    exit(code)
}

// MARK: - Options

var files: [String] = []
var token = ProcessInfo.processInfo.environment["MACWRIGHT_TOKEN"]
var server = ProcessInfo.processInfo.environment["MACWRIGHT_SERVER"]
var cliVars: [String: Value] = [:]
var junitPath: String?
var artifactsDir: String?
var failFast = false, checkOnly = false, verbose = false

var argv = Array(CommandLine.arguments.dropFirst())
func next(_ flag: String) -> String {
    guard !argv.isEmpty else { fail("\(flag) needs a value") }
    return argv.removeFirst()
}
while !argv.isEmpty {
    let a = argv.removeFirst()
    switch a {
    case "-h", "--help": print(usage); exit(0)
    case "--token": token = next(a)
    case "--server": server = next(a)
    case "--junit": junitPath = next(a)
    case "--artifacts": artifactsDir = next(a)
    case "--fail-fast": failFast = true
    case "--check": checkOnly = true
    case "--verbose", "-v": verbose = true
    case "--var":
        let kv = next(a)
        guard let eq = kv.firstIndex(of: "=") else { fail("--var takes name=value") }
        let raw = String(kv[kv.index(after: eq)...])
        // Numbers and booleans keep their type, like in a test file.
        let v: Value = Int(raw).map(Value.int) ?? Double(raw).map(Value.double)
            ?? (raw == "true" ? .bool(true) : raw == "false" ? .bool(false) : .string(raw))
        cliVars[String(kv[..<eq])] = v
    default:
        if a.hasPrefix("-") { fail("unknown option \(a)\n\n\(usage)") }
        files.append(a)
    }
}
if files.isEmpty { print(usage); exit(2) }

let tests: [TestFile]
do { tests = try Spec.collect(files).map { try Spec.load(path: $0) } } catch { fail("\(error)") }
if tests.isEmpty { fail("no test files found") }

// MARK: - MCP connection

struct ServerGone: Error, CustomStringConvertible {
    var description: String { "MacWright stopped answering during the call (locked or quit)" }
}

/// Runs its block the first time only, so a continuation is resumed exactly once.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ f: () -> Void) {
        lock.lock(); let first = !done; done = true; lock.unlock()
        if first { f() }
    }
}

struct MCPCaller: ToolCaller {
    let client: Client
    let endpoint: URL

    /// Whether anything still listens on the endpoint. An unauthenticated POST gets 401 from a
    /// live server; a locked or quit app refuses the connection.
    static func alive(_ url: URL) async -> Bool {
        var req = URLRequest(url: url, timeoutInterval: 2)
        req.httpMethod = "POST"
        return (try? await URLSession.shared.data(for: req)) != nil
    }

    func call(_ tool: String, _ args: [String: Value]) async throws -> ToolResult {
        // The MCP client keeps waiting if the server goes away mid-call (Lock cuts the session
        // without a reply), so race the call against a check that the server is still there.
        // A task group can't do this race: it waits for every child before returning, and the
        // stuck call ignores cancellation. So whichever side finishes first resumes the caller,
        // and the other is cancelled and left behind.
        let url = endpoint
        let client = self.client
        let once = Once()
        var work: Task<Void, Never>?
        var watch: Task<Void, Never>?
        let r: CallTool.Result = try await withCheckedThrowingContinuation { cont in
            work = Task {
                do { let v = try await client.callTool(name: tool, arguments: args).value; once.run { cont.resume(returning: v) } }
                catch { once.run { cont.resume(throwing: error) } }
            }
            watch = Task {
                var misses = 0
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                    misses = await MCPCaller.alive(url) ? 0 : misses + 1
                    if misses >= 2 { once.run { cont.resume(throwing: ServerGone()) }; return }
                }
            }
        }
        work?.cancel()
        watch?.cancel()
        if let s = r.structuredContent { return ToolResult(json: s, isError: r.isError ?? false) }
        // Fall back to the text content, which MacWright fills with the same JSON.
        for c in r.content {
            if case .text(let t, _, _) = c, let d = t.data(using: .utf8), let v = try? JSONDecoder().decode(Value.self, from: d) {
                return ToolResult(json: v, isError: r.isError ?? false)
            }
        }
        return ToolResult(json: .object([:]), isError: r.isError ?? false)
    }
}

@MainActor func endpoint() -> URL {
    if let server, let u = URL(string: server) { return u }
    // The app's port setting (`defaults write com.kuarasoft.macwright port -int …`), else the default.
    let port = UserDefaults(suiteName: "com.kuarasoft.macwright")?.integer(forKey: "port") ?? 0
    return URL(string: "http://127.0.0.1:\(port > 0 ? port : 47615)/mcp")!
}

@MainActor func connect() async -> Client {
    guard let token, !token.isEmpty else {
        fail("no token: pass --token or set MACWRIGHT_TOKEN (MacWright menu → Token → Copy token)")
    }
    let bearer = "Bearer \(token)"
    let url = endpoint()
    let config = URLSessionConfiguration.default
    // Tool calls can wait a long time (wait_for_window, record, when-triggers).
    config.timeoutIntervalForRequest = 900
    config.timeoutIntervalForResource = 3600
    let transport = HTTPClientTransport(endpoint: url, configuration: config, streaming: false, requestModifier: { req in
        var r = req
        r.setValue(bearer, forHTTPHeaderField: "Authorization")
        return r
    })
    let client = Client(name: "macwright-run", version: "1.0.0")
    do { _ = try await client.connect(transport: transport) } catch {
        fail("can't connect to MacWright at \(url) (\(error)). Is the app running and unlocked, and is the token current?")
    }
    return client
}

func checkToolNames(_ client: Client, _ tests: [TestFile]) async {
    var names: Set<String> = []
    var cursor: String?
    repeat {
        guard let page = try? await client.listTools(cursor: cursor) else { fail("tools/list failed") }
        names.formUnion(page.tools.map(\.name))
        cursor = page.nextCursor
    } while cursor != nil
    var bad: [String] = []
    for t in tests {
        for s in t.allSteps where !names.contains(s.tool) { bad.append("\(t.path): \(s.location): unknown tool `\(s.tool)`") }
    }
    if !bad.isEmpty { fail(bad.joined(separator: "\n")) }
}

// MARK: - Output

let tty = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
func paint(_ s: String, _ code: String) -> String { tty ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }

final class Console: RunObserver {
    func testStarted(_ file: TestFile) { print(paint(file.name, "1") + paint("  \(file.path)", "2")) }
    func stepFinished(_ r: StepResult) {
        let mark: String
        switch r.status {
        case .passed: mark = paint("✓", "32")
        case .failed: mark = paint("✗", "31")
        case .skipped: mark = paint("-", "2")
        }
        var line = "  \(mark) \(r.step.label)"
        if r.section != "steps" { line += paint(" (\(r.section))", "2") }
        if r.status != .skipped { line += paint("  \(r.ms) ms", "2") }
        if r.attempts > 1 { line += paint(", \(r.attempts) tries", "2") }
        print(line)
        if r.status == .failed, let m = r.message { print("    " + paint("\(r.step.location): \(m)", "31")) }
        if verbose, let res = r.result {
            print(jsonString(res, pretty: true).split(separator: "\n").map { "      " + $0 }.joined(separator: "\n"))
        }
    }
    func testFinished(_ r: TestResult) {
        for a in r.artifacts { print("    " + paint("screenshot: \(a)", "2")) }
        print("")
    }
}

// MARK: - Run

if checkOnly {
    if token != nil { let c = await connect(); await checkToolNames(c, tests); await c.disconnect() }
    print("\(tests.count) file(s), \(tests.reduce(0) { $0 + $1.allSteps.count }) step(s): OK")
    exit(0)
}

let client = await connect()
await checkToolNames(client, tests)
let caller = MCPCaller(client: client, endpoint: endpoint())

if let dir = artifactsDir {
    do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) } catch {
        fail("can't create \(dir): \(error.localizedDescription)")
    }
}
let artifactsAbs = artifactsDir.map { URL(fileURLWithPath: $0).standardizedFileURL.path }

var runner = Runner(caller: caller, vars: cliVars, observer: Console())
if let dir = artifactsAbs {
    runner.onFailure = { file, step in
        let safe = file.name.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let path = (dir as NSString).appendingPathComponent("\(String(safe))-\(step.step.location).png")
        let r = try? await caller.call("screenshot", ["path": .string(path), "inline": .bool(false), "format": .string("png")])
        return r?.isError == false ? [path] : []
    }
}

var results: [TestResult] = []
for t in tests {
    let r = await runner.run(t)
    results.append(r)
    if failFast && !r.passed { break }
}
await client.disconnect()

if let junitPath {
    do { try JUnit.xml(results).write(toFile: junitPath, atomically: true, encoding: .utf8) } catch {
        fail("can't write \(junitPath): \(error.localizedDescription)")
    }
}
let failedCount = results.filter { !$0.passed }.count
let passedCount = results.count - failedCount
let skippedFiles = tests.count - results.count
var summary = failedCount == 0 ? paint("\(passedCount) passed", "32") : paint("\(failedCount) failed", "31") + ", \(passedCount) passed"
if skippedFiles > 0 { summary += ", \(skippedFiles) not run" }
let ms = results.reduce(0) { $0 + $1.ms }
print(summary + paint(" (\(String(format: "%.1f", Double(ms) / 1000)) s)", "2"))
exit(failedCount == 0 ? 0 : 1)
