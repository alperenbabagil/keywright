import Foundation
import MCP
import XCTest
@testable import KeywrightCore

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

    /// Crafted chunk sizes used to crash the parser (negative range, integer overflow).
    func testBadChunkSizesAreRejectedNotCrashing() {
        for size in ["-5", "7fffffffffffffff", "ffffffffffffffff0", "2000001"] {
            let raw = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n\(size)\r\nabc\r\n0\r\n\r\n"
            guard case .bad = parseHTTPRequest(Data(raw.utf8)) else { return XCTFail("chunk size \(size) not rejected") }
        }
        // Many small chunks can't add up past the body limit either.
        var many = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        let chunk = "100000\r\n" + String(repeating: "a", count: 0x100000) + "\r\n"
        for _ in 0..<33 { many += chunk }
        guard case .bad = parseHTTPRequest(Data(many.utf8)) else { return XCTFail("oversized chunked body accepted") }
    }

    func testHeadIsAvailableBeforeTheBody() {
        let raw = "POST /mcp HTTP/1.1\r\nAuthorization: Bearer x\r\nContent-Length: 30000000\r\n\r\nab"
        guard case .incomplete = parseHTTPRequest(Data(raw.utf8)) else { return XCTFail() }
        let h = parseHTTPHead(Data(raw.utf8))
        XCTAssertEqual(h?.path, "/mcp")
        XCTAssertEqual(h?.header("authorization"), "Bearer x")
        XCTAssertNil(parseHTTPHead(Data("POST /mcp HTTP/1.1\r\nAuth".utf8)))
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
            // Not cancellable, like Keywright's tools, which run on their own serial queue.
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

    /// The token is checked as soon as the headers arrive: a client without it gets 401 at once,
    /// without Keywright buffering (or waiting for) a large body.
    func testWrongTokenIsRefusedBeforeTheBody() throws {
        let c = try rawSocket()
        defer { close(c) }
        let head = "POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer wrong\r\nContent-Length: 30000000\r\n\r\n"
        _ = head.withCString { send(c, $0, strlen($0), 0) }
        XCTAssertTrue(readReply(c).hasPrefix("HTTP/1.1 401"))
    }

    /// A client that connects and sends nothing (or only part of its headers) is dropped.
    func testSilentAndSlowClientsAreDropped() throws {
        let h = MCPHTTPHost(port: 0, headerTimeout: 0.3, requestTimeout: 0.8, token: { "t" },
                            serverFactory: { Server(name: "x", version: "1") })
        try h.start()
        defer { h.stop() }
        let saved = host
        host = h
        defer { host = saved }

        let silent = try rawSocket()
        defer { close(silent) }
        let partial = try rawSocket()
        defer { close(partial) }
        _ = "POST /mcp HTTP/1.1\r\nHost: x\r\n".withCString { send(partial, $0, strlen($0), 0) }
        // Headers complete with the right token, body never sent: dropped at the request timeout.
        let slowBody = try rawSocket()
        defer { close(slowBody) }
        _ = "POST /mcp HTTP/1.1\r\nAuthorization: Bearer t\r\nContent-Length: 100\r\n\r\nab".withCString { send(slowBody, $0, strlen($0), 0) }

        let t = Date()
        XCTAssertEqual(readReply(silent), "")     // closed without a reply
        XCTAssertEqual(readReply(partial), "")
        XCTAssertLessThan(Date().timeIntervalSince(t), 1.5)
        XCTAssertEqual(readReply(slowBody), "")
        let total = Date().timeIntervalSince(t)
        XCTAssertGreaterThan(total, 0.6)          // the head arrived, so only the request timeout applies
        XCTAssertLessThan(total, 2)
    }

    func rawSocket() throws -> Int32 {
        let c = socket(AF_INET, SOCK_STREAM, 0)
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = host.port!.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(c, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0 else { throw URLError(.cannotConnectToHost) }
        return c
    }

    func readReply(_ c: Int32) -> String {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(c, &buf, buf.count, 0)
        return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
    }

    func testWrongPathIs404() async throws {
        let (status, _, _) = try await post(initialize, auth: "Bearer \(HTTPAuthTests.token)",
                                            url: URL(string: "http://127.0.0.1:\(host.port!)/other")!)
        XCTAssertEqual(status, 404)
    }

    /// With approval on, a new session waits for the owner's answer, sees which process connects,
    /// and then answers only that process.
    func testSessionsNeedApprovalAndStayWithTheirProcess() async throws {
        let seen = Box<PeerProcess?>(nil)
        let allow = Box(false)
        await host.setApproveSession { peer in seen.value = peer; return allow.value }
        let auth = "Bearer \(HTTPAuthTests.token)"

        let (denied, _, _) = try await post(initialize, auth: auth)
        XCTAssertEqual(denied, 403)
        XCTAssertEqual(seen.value?.pid, getpid())          // the client here is this test process

        allow.value = true
        let (ok, headers, _) = try await post(initialize, auth: auth)
        XCTAssertEqual(ok, 200)
        let sid = try XCTUnwrap(headers.value(forHTTPHeaderField: "Mcp-Session-Id"))
        let (same, _, _) = try await post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, auth: auth, session: sid)
        XCTAssertEqual(same, 200)

        // Another process with the token and the session ID is still refused.
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-s", "-o", "/dev/null", "-w", "%{http_code}", "-X", "POST", base.absoluteString,
                          "-H", "Authorization: \(auth)", "-H", "Mcp-Session-Id: \(sid)", "-H", "MCP-Protocol-Version: 2025-06-18",
                          "-H", "Content-Type: application/json", "-H", "Accept: application/json, text/event-stream",
                          "-d", #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#]
        let out = Pipe()
        curl.standardOutput = out
        try curl.run()
        curl.waitUntilExit()
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "403")
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

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}
