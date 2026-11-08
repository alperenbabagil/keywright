// MCP Streamable HTTP host: a small HTTP/1.1 server on Network.framework in front of the MCP SDK's
// StatefulHTTPServerTransport. Every request must carry `Authorization: Bearer <token>`.
// One MCP session (Server + transport) per `initialize`, routed by the Mcp-Session-Id header.
import Foundation
import MCP
import Network

/// A parsed HTTP request (method, path without query, headers with original casing, body).
public struct RawHTTPRequest {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data
    public func header(_ name: String) -> String? {
        let l = name.lowercased()
        return headers.first { $0.key.lowercased() == l }?.value
    }
}

public enum HTTPParse {
    case incomplete
    case bad(String)
    case done(RawHTTPRequest, consumed: Int)
}

/// Largest request body accepted, whether sent with Content-Length or chunked.
public let maxHTTPBody = 32 * 1024 * 1024

/// The request line and headers, once they have all arrived (the body may still be on its way),
/// so the token can be checked before any body is buffered. Nil while incomplete or malformed.
public func parseHTTPHead(_ buf: Data) -> RawHTTPRequest? {
    guard case .some(.success(let h)) = head(buf) else { return nil }
    return h.request
}

private func head(_ buf: Data) -> Result<(request: RawHTTPRequest, end: Data.Index), HeadError>? {
    let sep = Data("\r\n\r\n".utf8)
    guard let headEnd = buf.range(of: sep) else {
        return buf.count > 64 * 1024 ? .failure(HeadError(why: "headers too large")) : nil
    }
    guard let text = String(data: buf[buf.startIndex..<headEnd.lowerBound], encoding: .utf8) else { return .failure(HeadError(why: "bad header encoding")) }
    var lines = text.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count >= 2 else { return .failure(HeadError(why: "bad request line")) }
    var headers: [String: String] = [:]
    for line in lines {
        guard let colon = line.firstIndex(of: ":") else { continue }
        headers[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] =
            String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }
    let req = RawHTTPRequest(method: String(requestLine[0]).uppercased(),
                             path: String(requestLine[1].split(separator: "?", maxSplits: 1).first ?? ""),
                             headers: headers, body: Data())
    return .success((req, headEnd.upperBound))
}

private struct HeadError: Error { let why: String }

/// Parses one HTTP/1.1 request from the front of [buf] (Content-Length or chunked bodies).
public func parseHTTPRequest(_ buf: Data) -> HTTPParse {
    let sep = Data("\r\n\r\n".utf8)
    let parsed: (request: RawHTTPRequest, end: Data.Index)
    switch head(buf) {
    case nil: return .incomplete
    case .failure(let e): return .bad(e.why)
    case .success(let h): parsed = h
    }
    var req = parsed.request
    let bodyStart = parsed.end
    if req.header("Transfer-Encoding")?.lowercased().contains("chunked") == true {
        var i = bodyStart
        var body = Data()
        while true {
            guard let lineEnd = buf[i...].range(of: Data("\r\n".utf8)) else { return .incomplete }
            let sizeText = String(data: buf[i..<lineEnd.lowerBound], encoding: .utf8)?
                .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            // Hex digits only (Int(radix:) would take a sign), and never past the body limit, so
            // the index arithmetic below can't overflow or go backwards.
            guard !sizeText.isEmpty, sizeText.count <= 8, sizeText.allSatisfy(\.isHexDigit),
                  let size = Int(sizeText, radix: 16), body.count + size <= maxHTTPBody else { return .bad("bad chunk size") }
            let dataStart = lineEnd.upperBound
            if size == 0 {
                // Skip optional trailers up to the blank line.
                guard let end = buf[lineEnd.lowerBound...].range(of: sep) else {
                    return buf.count >= dataStart + 2 && buf[dataStart..<dataStart + 2] == Data("\r\n".utf8)
                        ? .done(withBody(req, body), consumed: dataStart + 2 - buf.startIndex) : .incomplete
                }
                return .done(withBody(req, body), consumed: end.upperBound - buf.startIndex)
            }
            guard buf.endIndex >= dataStart + size + 2 else { return .incomplete }
            body.append(buf[dataStart..<dataStart + size])
            i = dataStart + size + 2
        }
    }
    let length = Int(req.header("Content-Length") ?? "0") ?? -1
    guard length >= 0, length <= maxHTTPBody else { return .bad("bad Content-Length") }
    guard buf.endIndex - bodyStart >= length else { return .incomplete }
    req.body = buf[bodyStart..<bodyStart + length]
    return .done(req, consumed: bodyStart + length - buf.startIndex)
}

private func withBody(_ r: RawHTTPRequest, _ body: Data) -> RawHTTPRequest {
    var r = r; r.body = body; return r
}

// MARK: - Session routing

/// True when [body] is a single JSON-RPC `initialize` request.
func isInitialize(_ body: Data) -> Bool {
    guard let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
    return o["method"] as? String == "initialize" && o["id"] != nil
}

/// Creates and finds MCP sessions. Each `initialize` gets a fresh Server + stateful transport.
actor SessionRouter {
    struct Session { let server: Server; let transport: StatefulHTTPServerTransport; var lastUsed: Date }
    private var sessions: [String: Session] = [:]
    private let factory: @Sendable () async throws -> Server
    private let idleTimeout: TimeInterval

    init(factory: @escaping @Sendable () async throws -> Server, idleTimeout: TimeInterval) {
        self.factory = factory
        self.idleTimeout = idleTimeout
    }

    var count: Int { sessions.count }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        expire()
        let sid = request.header(HTTPHeaderName.sessionID)
        if let sid, var s = sessions[sid] {
            s.lastUsed = Date()
            sessions[sid] = s
            let resp = await s.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE", resp.statusCode == 200 {
                sessions.removeValue(forKey: sid)
                await s.server.stop()
            }
            return resp
        }
        if request.method.uppercased() == "POST", let body = request.body, isInitialize(body) {
            return await create(request)
        }
        if sid != nil { return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired")) }
        return .error(statusCode: 400, .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header"))
    }

    private struct FixedID: SessionIDGenerator {
        let id: String
        func generateSessionID() -> String { id }
    }

    private func create(_ request: HTTPRequest) async -> HTTPResponse {
        let sid = UUID().uuidString
        let transport = StatefulHTTPServerTransport(sessionIDGenerator: FixedID(id: sid))
        do {
            let server = try await factory()
            try await server.start(transport: transport)
            sessions[sid] = Session(server: server, transport: transport, lastUsed: Date())
            let resp = await transport.handleRequest(request)
            if case .error = resp {
                sessions.removeValue(forKey: sid)
                await server.stop()
            }
            return resp
        } catch {
            await transport.disconnect()
            return .error(statusCode: 500, .internalError("Failed to create session: \(error.localizedDescription)"))
        }
    }

    private func expire() {
        let now = Date()
        for (sid, s) in sessions where now.timeIntervalSince(s.lastUsed) > idleTimeout {
            sessions.removeValue(forKey: sid)
            Task { await s.server.stop() }
        }
    }

    func closeAll() async {
        for (_, s) in sessions { await s.server.stop() }
        sessions.removeAll()
    }
}

// MARK: - Listener

public final class MCPHTTPHost: @unchecked Sendable {
    public let host: String
    public let endpoint: String
    private let requestedPort: UInt16
    /// A client must send its headers within headerTimeout and the whole request within
    /// requestTimeout, or the connection is dropped, so idle or very slow clients can't pile up.
    /// A response that streams for a long time (a long tool call) isn't affected.
    private let headerTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let token: @Sendable () -> String
    private let router: SessionRouter
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "macwright.http")
    /// Open client connections, so stop() can cut them: a client waiting on a call gets an error
    /// at once instead of hanging, and nothing more is written to it.
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let connLock = NSLock()
    private var stopped = false
    /// Called (on an arbitrary queue) for each request: method, path, status.
    public var onRequest: (@Sendable (String, String, Int) -> Void)?
    /// Called when the listener's state changes: nil = ready, else an error text.
    public var onState: (@Sendable (String?) -> Void)?

    public init(host: String = "127.0.0.1", port: UInt16, endpoint: String = "/mcp",
                idleTimeout: TimeInterval = 6 * 3600,
                headerTimeout: TimeInterval = 10, requestTimeout: TimeInterval = 30,
                token: @escaping @Sendable () -> String,
                serverFactory: @escaping @Sendable () async throws -> Server) {
        self.host = host
        self.requestedPort = port
        self.headerTimeout = headerTimeout
        self.requestTimeout = requestTimeout
        self.endpoint = endpoint
        self.token = token
        self.router = SessionRouter(factory: serverFactory, idleTimeout: idleTimeout)
    }

    /// The bound port (useful when started with port 0).
    public var port: UInt16? { listener?.port?.rawValue }

    /// Starts listening; returns once the listener is ready (or throws).
    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host),
                                                 port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        let l = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onState?(nil); ready.signal()
            case .failed(let e): failure = e; self?.onState?("\(e)"); ready.signal()
            case .cancelled: ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        connLock.withLock { stopped = false }
        l.start(queue: queue)
        listener = l
        _ = ready.wait(timeout: .now() + 5)
        if let failure { l.cancel(); listener = nil; throw failure }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        let open = connLock.withLock { () -> [NWConnection] in
            stopped = true
            let all = Array(connections.values)
            connections.removeAll()
            return all
        }
        for c in open { c.cancel() }
        let r = router
        Task { await r.closeAll() }
    }

    /// Open connections (for tests).
    public var openConnections: Int { connLock.withLock { connections.count } }

    private func forget(_ c: NWConnection) {
        _ = connLock.withLock { connections.removeValue(forKey: ObjectIdentifier(c)) }
    }

    private func track(_ c: NWConnection, onEnd: (() -> Void)? = nil) {
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.forget(c); onEnd?()
            default: break
            }
        }
    }

    private func accept(_ c: NWConnection) {
        // Refuse if stop() already ran (a connection accepted just before the listener closed).
        let accepted = connLock.withLock { () -> Bool in
            if stopped { return false }
            connections[ObjectIdentifier(c)] = c
            return true
        }
        guard accepted else { c.cancel(); return }
        track(c)
        c.start(queue: queue)
        let progress = RequestProgress()
        queue.asyncAfter(deadline: .now() + headerTimeout) { if !progress.head { c.cancel() } }
        queue.asyncAfter(deadline: .now() + requestTimeout) { if !progress.done { c.cancel() } }
        receive(c, Data(), checked: false, progress: progress)
    }

    /// How far a connection's request has arrived; only touched on `queue`.
    private final class RequestProgress: @unchecked Sendable {
        var head = false
        var done = false
    }

    private func receive(_ c: NWConnection, _ buf: Data, checked: Bool, progress: RequestProgress) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buf
            if let data { buf.append(data) }
            // Path and token are checked as soon as the headers are in, before any body is kept.
            var checked = checked
            if !checked, let head = parseHTTPHead(buf) {
                progress.head = true
                if self.refuse(c, head) { progress.done = true; return }
                checked = true
            }
            switch parseHTTPRequest(buf) {
            case .done(let req, _):
                progress.head = true
                progress.done = true
                Task { await self.respond(c, req) }
            case .bad(let why):
                progress.head = true
                progress.done = true
                self.write(c, status: 400, headers: ["Content-Type": "text/plain"], body: Data(why.utf8))
            case .incomplete:
                if isComplete || error != nil { c.cancel() } else { self.receive(c, buf, checked: checked, progress: progress) }
            }
        }
    }

    /// Answers 404 or 401 and returns true when the request must go no further.
    private func refuse(_ c: NWConnection, _ raw: RawHTTPRequest) -> Bool {
        guard raw.path == endpoint else {
            onRequest?(raw.method, raw.path, 404)
            write(c, status: 404, headers: ["Content-Type": "text/plain"], body: Data("Not Found".utf8))
            return true
        }
        guard bearerMatches(raw.header("Authorization"), token: token()) else {
            onRequest?(raw.method, raw.path, 401)
            let body = #"{"jsonrpc":"2.0","error":{"code":-32001,"message":"Unauthorized: missing or wrong bearer token"},"id":null}"#
            write(c, status: 401, headers: ["Content-Type": "application/json",
                                            "WWW-Authenticate": #"Bearer realm="MacWright""#], body: Data(body.utf8))
            return true
        }
        return false
    }

    private func respond(_ c: NWConnection, _ raw: RawHTTPRequest) async {
        // Checked again on the full request: the token may have been regenerated meanwhile.
        if refuse(c, raw) { return }
        let req = HTTPRequest(method: raw.method, headers: raw.headers,
                              body: raw.body.isEmpty ? nil : raw.body, path: raw.path)
        let resp = await router.handle(req)
        onRequest?(raw.method, raw.path, resp.statusCode)
        if case .stream(let stream, let headers) = resp {
            writeStream(c, headers: headers, stream: stream)
        } else {
            write(c, status: resp.statusCode, headers: resp.headers, body: resp.bodyData ?? Data())
        }
    }

    private static func reason(_ s: Int) -> String {
        [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
         404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable", 415: "Unsupported Media Type",
         500: "Internal Server Error"][s] ?? "Status"
    }

    private func head(_ status: Int, _ headers: [String: String]) -> Data {
        var s = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        s += "Connection: close\r\n\r\n"
        return Data(s.utf8)
    }

    private func write(_ c: NWConnection, status: Int, headers: [String: String], body: Data) {
        var h = headers
        h["Content-Length"] = String(body.count)
        c.send(content: head(status, h) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    /// SSE response: chunked transfer encoding, one chunk per event, closed when the stream ends
    /// or the client goes away.
    private func writeStream(_ c: NWConnection, headers: [String: String], stream: AsyncThrowingStream<Data, Error>) {
        var h = headers
        h["Transfer-Encoding"] = "chunked"
        if h["Content-Type"] == nil { h["Content-Type"] = "text/event-stream" }
        h["Cache-Control"] = "no-cache"
        c.send(content: head(200, h), completion: .contentProcessed { _ in })
        let task = Task {
            do {
                for try await chunk in stream where !chunk.isEmpty {
                    let framed = Data(String(chunk.count, radix: 16).utf8) + Data("\r\n".utf8) + chunk + Data("\r\n".utf8)
                    c.send(content: framed, completion: .contentProcessed { _ in })
                }
            } catch {}
            c.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in c.cancel() })
        }
        track(c) { task.cancel() }
    }
}
