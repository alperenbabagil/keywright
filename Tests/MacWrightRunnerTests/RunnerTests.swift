import MCP
import XCTest
@testable import MacWrightRunnerCore

/// Answers tool calls from a script: each tool name maps to a list of results, used in order
/// (the last one repeats).
final class FakeCaller: ToolCaller {
    var script: [String: [ToolResult]]
    var calls: [(String, [String: Value])] = []
    init(_ script: [String: [ToolResult]]) { self.script = script }
    func call(_ tool: String, _ args: [String: Value]) async throws -> ToolResult {
        calls.append((tool, args))
        guard var list = script[tool], !list.isEmpty else { return ToolResult(json: ["ok": true], isError: false) }
        let r = list.removeFirst()
        if !list.isEmpty { script[tool] = list }
        return r
    }
}

func ok(_ o: [String: Value]) -> ToolResult { var o = o; o["ok"] = true; return ToolResult(json: .object(o), isError: false) }
func err(_ m: String) -> ToolResult { ToolResult(json: ["ok": false, "error": .string(m)], isError: true) }

final class SpecTests: XCTestCase {
    func testParsesStepsAndReservedKeys() throws {
        let f = try Spec.parse("""
            name: TextEdit
            vars: {app: TextEdit}
            setup:
              - launch_app: {app: "${app}"}
            steps:
              - name: Type
                type_text: {text: hi}
                expect: {ok: true}
              - release_all
              - wait_for_ax: {app: TextEdit}
                retry: {timeoutMs: 2000, intervalMs: 100}
                expect: {found: true}
                save: {el: "matches[0]"}
              - key: {key: esc}
                expectError: refuse
            teardown:
              - quit_app: {app: TextEdit}
            """, path: "/x/textedit.yml")
        XCTAssertEqual(f.name, "TextEdit")
        XCTAssertEqual(f.setup.map(\.tool), ["launch_app"])
        XCTAssertEqual(f.steps.map(\.tool), ["type_text", "release_all", "wait_for_ax", "key"])
        XCTAssertEqual(f.steps[0].label, "Type")
        XCTAssertEqual(f.steps[2].retry, Retry(timeoutMs: 2000, intervalMs: 100))
        XCTAssertEqual(f.steps[2].save.first?.path, "matches[0]")
        XCTAssertEqual(f.steps[3].expectError, .containing("refuse"))
        XCTAssertEqual(f.steps[3].location, "steps[3]")
        XCTAssertEqual(f.teardown.count, 1)
    }

    func testJSONFilesWork() throws {
        let f = try Spec.parse(#"{"steps": [{"status": {}}, {"cursor": null}]}"#, path: "a/b.json")
        XCTAssertEqual(f.name, "b")
        XCTAssertEqual(f.steps.map(\.tool), ["status", "cursor"])
    }

    func testRejectsBadSteps() {
        XCTAssertThrowsError(try Spec.parse("steps:\n  - {key: {key: a}, click: {}}")) {
            XCTAssertTrue("\($0)".contains("one tool per step"))
        }
        XCTAssertThrowsError(try Spec.parse("steps:\n  - {name: x}")) { XCTAssertTrue("\($0)".contains("no tool")) }
        XCTAssertThrowsError(try Spec.parse("stepz: []")) { XCTAssertTrue("\($0)".contains("unknown key")) }
        XCTAssertThrowsError(try Spec.parse("steps:\n  - status: {}\n    retry: 500")) { XCTAssertTrue("\($0)".contains("needs `expect`")) }
        XCTAssertThrowsError(try Spec.parse("steps:\n  - status: {}\n    expect: {x: {matches: '('}}")) { XCTAssertTrue("\($0)".contains("regular expression")) }
    }
}

final class MatchTests: XCTestCase {
    let result: Value = ["windows": [["title": "Untitled", "id": 7, "bounds": ["w": 800]], ["title": "Prefs", "id": 9]],
                         "cursor": ["x": 10.0, "hidden": false], "name": "TextEdit"]

    func path(_ s: String) -> Value? { try! Path.parse(s).resolve(result) }

    func testPaths() {
        XCTAssertEqual(path("windows[1].title"), "Prefs")
        XCTAssertEqual(path("windows.0.id"), 7)
        XCTAssertEqual(path("windows[-1].id"), 9)
        XCTAssertNil(path("windows[5]"))
        XCTAssertNil(path("cursor.y"))
    }

    func testLiteralsAndSubsets() {
        XCTAssertNil(Match.check(10, path("cursor.x")))  // 10 == 10.0
        XCTAssertNil(Match.check(["title": "Untitled"], path("windows[0]")))  // subset of a map
        XCTAssertNotNil(Match.check("Prefs", path("windows[0].title")))
        XCTAssertNotNil(Match.check(true, path("missing")))
    }

    func testOperators() {
        XCTAssertNil(Match.check(["contains": ["title": "Prefs"]], path("windows")))
        XCTAssertNil(Match.check(["contains": "Text"], path("name")))
        XCTAssertNil(Match.check(["matches": "^Text"], path("name")))
        XCTAssertNil(Match.check(["length": 2], path("windows")))
        XCTAssertNil(Match.check(["length": ["gte": 1]], path("windows")))
        XCTAssertNil(Match.check(["gt": 5, "lte": 10], path("cursor.x")))
        XCTAssertNotNil(Match.check(["gt": 10], path("cursor.x")))
        XCTAssertNil(Match.check(["exists": false], path("cursor.y")))
        XCTAssertNil(Match.check(["not": true], path("cursor.hidden")))
        XCTAssertNil(Match.check(["any": ["Finder", ["matches": "Edit$"]]], path("name")))
        XCTAssertNil(Match.check(["all": [["contains": "Text"], ["contains": "Edit"]]], path("name")))
        XCTAssertNil(Match.check(["contains": ["bounds": ["w": ["gt": 500]]]], path("windows")))
    }

    func testInterpolation() throws {
        let vars: [String: Value] = ["win": ["id": 7, "title": "Untitled"], "n": 3]
        XCTAssertEqual(try Interpolate.apply("${n}", vars: vars, env: [:]), 3)  // keeps its type
        XCTAssertEqual(try Interpolate.apply("${win.id}", vars: vars, env: [:]), 7)
        XCTAssertEqual(try Interpolate.apply("w ${win.title} #${n}", vars: vars, env: [:]), "w Untitled #3")
        XCTAssertEqual(try Interpolate.apply("${env.HOME}/a", vars: [:], env: ["HOME": "/h"]), "/h/a")
        XCTAssertThrowsError(try Interpolate.apply("${nope}", vars: vars, env: [:]))
    }
}

final class RunTests: XCTestCase {
    func testPassSaveAndInterpolate() async throws {
        let f = try Spec.parse("""
            steps:
              - list_windows: {app: TextEdit}
                expect: {windows: {length: {gte: 1}}}
                save: {win: "windows[0]"}
              - screenshot: {window: "${win.id}"}
            """)
        let caller = FakeCaller(["list_windows": [ok(["windows": [["id": 42, "title": "Untitled"]]])]])
        let r = await Runner(caller: caller, env: [:]).run(f)
        XCTAssertTrue(r.passed)
        XCTAssertEqual(caller.calls[1].1["window"], 42)
    }

    func testFailureSkipsRestButRunsTeardown() async throws {
        let f = try Spec.parse("""
            steps:
              - click: {}
              - key: {key: a}
            teardown:
              - quit_app: {app: X}
            """)
        let caller = FakeCaller(["click": [err("paused")]])
        var shots = 0
        let r = await Runner(caller: caller, env: [:], onFailure: { _, _ in shots += 1; return ["/tmp/s.png"] }).run(f)
        XCTAssertFalse(r.passed)
        XCTAssertEqual(r.steps.map(\.status), [.failed, .skipped, .passed])
        XCTAssertEqual(r.failure?.message, "paused")
        XCTAssertEqual(caller.calls.map(\.0), ["click", "quit_app"])
        XCTAssertEqual(shots, 1)
        XCTAssertEqual(r.artifacts, ["/tmp/s.png"])
    }

    func testRetryUntilExpectPasses() async throws {
        let f = try Spec.parse("""
            steps:
              - ax_find: {app: X}
                retry: {timeoutMs: 5000, intervalMs: 1}
                expect: {count: {gte: 1}}
            """)
        let caller = FakeCaller(["ax_find": [ok(["count": 0]), ok(["count": 0]), ok(["count": 2])]])
        let r = await Runner(caller: caller, env: [:]).run(f)
        XCTAssertTrue(r.passed)
        XCTAssertEqual(r.steps[0].attempts, 3)
    }

    func testRetryGivesUp() async throws {
        let f = try Spec.parse("steps:\n  - ax_find: {}\n    retry: {timeoutMs: 30, intervalMs: 5}\n    expect: {count: 1}")
        let r = await Runner(caller: FakeCaller(["ax_find": [ok(["count": 0])]]), env: [:]).run(f)
        XCTAssertFalse(r.passed)
        XCTAssertTrue(r.failure!.message!.contains("count: expected 1, got 0"))
    }

    func testExpectError() async throws {
        let f = try Spec.parse("steps:\n  - key: {key: esc}\n    expectError: terminal\n  - click: {}\n    expectError: true")
        let r = await Runner(caller: FakeCaller(["key": [err("refused: a terminal is active")]]), env: [:]).run(f)
        XCTAssertEqual(r.steps.map(\.status), [.passed, .failed])
        XCTAssertEqual(r.steps[1].message, "expected an error, the call succeeded")
    }

    func testJUnit() async throws {
        let f = try Spec.parse("name: A & B\nsteps:\n  - click: {}\n  - key: {key: a}", path: "t.yml")
        let r = await Runner(caller: FakeCaller(["click": [err("bad <thing>")]]), env: [:]).run(f)
        let x = JUnit.xml([r])
        XCTAssertTrue(x.contains(#"<testsuite name="A &amp; B""#))
        XCTAssertTrue(x.contains(#"failures="1""#))
        XCTAssertTrue(x.contains(#"<failure message="bad &lt;thing&gt;">"#))
        XCTAssertTrue(x.contains("<skipped/>"))
    }
}
