import Foundation
import MCP
import XCTest
@testable import MacWrightCore

final class BearerTests: XCTestCase {
    func testBearerMatching() {
        XCTAssertTrue(bearerMatches("Bearer abc123", token: "abc123"))
        XCTAssertTrue(bearerMatches("bearer abc123", token: "abc123"))
        XCTAssertTrue(bearerMatches("  Bearer   abc123 ", token: "abc123"))
        XCTAssertFalse(bearerMatches(nil, token: "abc123"))
        XCTAssertFalse(bearerMatches("", token: "abc123"))
        XCTAssertFalse(bearerMatches("abc123", token: "abc123"))
        XCTAssertFalse(bearerMatches("Basic abc123", token: "abc123"))
        XCTAssertFalse(bearerMatches("Bearer abc12", token: "abc123"))
        XCTAssertFalse(bearerMatches("Bearer abc1234", token: "abc123"))
        XCTAssertFalse(bearerMatches("Bearer ", token: ""))
    }

    func testGeneratedTokens() {
        let a = TokenStore.generate(), b = TokenStore.generate()
        XCTAssertEqual(a.count, 64)
        XCTAssertNotEqual(a, b)
    }

    func testParseContentLengthAndChunked() {
        let raw = "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 5\r\n\r\nhello"
        guard case .done(let r, let used) = parseHTTPRequest(Data(raw.utf8)) else { return XCTFail() }
        XCTAssertEqual(r.method, "POST"); XCTAssertEqual(r.path, "/mcp")
        XCTAssertEqual(String(data: r.body, encoding: .utf8), "hello"); XCTAssertEqual(used, raw.utf8.count)

        guard case .incomplete = parseHTTPRequest(Data(raw.dropLast(2).utf8)) else { return XCTFail() }

        let chunked = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nhel\r\n2\r\nlo\r\n0\r\n\r\n"
        guard case .done(let c, _) = parseHTTPRequest(Data(chunked.utf8)) else { return XCTFail() }
        XCTAssertEqual(String(data: c.body, encoding: .utf8), "hello")
    }
}

/// Token auth on the real HTTP layer: a live MCPHTTPHost on an ephemeral port.
final class HTTPAuthTests: XCTestCase {
    static let token = "test-token-0123456789"
    var host: MCPHTTPHost!
    var base: URL!

    override func setUpWithError() throws {
        host = MCPHTTPHost(port: 0, token: { HTTPAuthTests.token }, serverFactory: {
            let s = Server(name: "test", version: "1", capabilities: .init(tools: .init(listChanged: false)))
            await s.withMethodHandler(ListTools.self) { _ in
                .init(tools: [Tool(name: "ping_tool", description: "x", inputSchema: ["type": "object"])])
            }
            // A call that takes 20 s, like a long recording, to check what stop() does to it.
            // Not cancellable, like MacWright's tools, which run on their own serial queue.
            await s.withMethodHandler(CallTool.self) { _ in
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 20) { c.resume() }
                }
                return .init(content: [.text(text: "late", annotations: nil, _meta: nil)])
            }
            return s
        })
        try host.start()
        base = URL(string: "http://127.0.0.1:\(host.port!)/mcp")!
    }

    override func tearDown() { host?.stop() }

    let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#

    func post(_ body: String, auth: String?, session: String? = nil, url: URL? = nil) async throws -> (Int, HTTPURLResponse, String) {
        var req = URLRequest(url: url ?? base)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let auth { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        if let session {
            req.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
            req.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as! HTTPURLResponse
        return (http.statusCode, http, String(data: data, encoding: .utf8) ?? "")
    }

    func testRejectsMissingToken() async throws {
        let (status, headers, _) = try await post(initialize, auth: nil)
        XCTAssertEqual(status, 401)
        XCTAssertNotNil(headers.value(forHTTPHeaderField: "WWW-Authenticate"))
    }

    func testRejectsWrongToken() async throws {
        let (status, _, _) = try await post(initialize, auth: "Bearer wrong")
        XCTAssertEqual(status, 401)
        let (s2, _, _) = try await post(initialize, auth: HTTPAuthTests.token)  // no "Bearer"
        XCTAssertEqual(s2, 401)
    }

    func testWrongPathIs404() async throws {
        let (status, _, _) = try await post(initialize, auth: "Bearer \(HTTPAuthTests.token)",
                                            url: URL(string: "http://127.0.0.1:\(host.port!)/other")!)
        XCTAssertEqual(status, 404)
    }

    func testAcceptsTokenAndServesMCP() async throws {
        let auth = "Bearer \(HTTPAuthTests.token)"
        let (status, headers, body) = try await post(initialize, auth: auth)
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.contains("serverInfo"), body)
        let sid = headers.value(forHTTPHeaderField: "Mcp-Session-Id")
        XCTAssertNotNil(sid)

        let (s2, _, _) = try await post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, auth: auth, session: sid)
        XCTAssertEqual(s2, 202)
        let (s3, _, list) = try await post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, auth: auth, session: sid)
        XCTAssertEqual(s3, 200)
        XCTAssertTrue(list.contains("ping_tool"), list)

        // A valid session is still refused without the token.
        let (s4, _, _) = try await post(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#, auth: nil, session: sid)
        XCTAssertEqual(s4, 401)

        // A second client can initialize its own session.
        let (s5, _, _) = try await post(initialize, auth: auth)
        XCTAssertEqual(s5, 200)
    }

    /// Lock: a client waiting on a running call is cut off at once, not left hanging until the
    /// call ends, and new connections are refused.
    func testStopCutsAClientWaitingOnACall() async throws {
        let auth = "Bearer \(HTTPAuthTests.token)"
        let (_, headers, _) = try await post(initialize, auth: auth)
        let sid = headers.value(forHTTPHeaderField: "Mcp-Session-Id")
        _ = try await post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, auth: auth, session: sid)

        let t0 = Date()
        let call = Task { () -> String in
            do {
                let (_, _, body) = try await self.post(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"slow","arguments":{}}}"#,
                                                       auth: auth, session: sid)
                return body
            } catch { return "error" }
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertGreaterThan(host.openConnections, 0)
        host.stop()
        XCTAssertEqual(host.openConnections, 0)
        let port = host.port
        host = nil  // the app drops its host right after stop()
        let outcome = await call.value
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3, "the client should not wait for the call to finish")
        XCTAssertFalse(outcome.contains("late"), outcome)
        _ = port

        do {
            _ = try await post(initialize, auth: auth)
            XCTFail("connected after stop")
        } catch {}
    }
}
