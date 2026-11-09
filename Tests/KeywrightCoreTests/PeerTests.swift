import Darwin
import XCTest
@testable import KeywrightCore

final class PeerTests: XCTestCase {
    /// A socket this test opens to a local listener is found, and attributed to this process.
    func testFindsTheProcessBehindALocalConnection() throws {
        let server = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(server) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        a.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(server, $0, len) } }
        Darwin.listen(server, 1)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &len) } }
        let serverPort = UInt16(bigEndian: a.sin_port)

        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, len) } }
        var c = sockaddr_in()
        _ = withUnsafeMutablePointer(to: &c) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(client, $0, &len) } }
        let clientPort = UInt16(bigEndian: c.sin_port)

        let t = Date()
        let peer = Peer.find(clientPort: clientPort, serverPort: serverPort)
        print("peer lookup took \(Int(Date().timeIntervalSince(t) * 1000)) ms")
        XCTAssertEqual(peer?.pid, getpid())
        XCTAssertNil(Peer.find(clientPort: clientPort &+ 1, serverPort: serverPort))
    }

    func testDisplayName() {
        XCTAssertEqual(PeerProcess.displayName("/Users/a/.local/share/claude/versions/2.1.319"), "claude 2.1.319")
        XCTAssertEqual(PeerProcess.displayName("/usr/local/bin/node"), "node")
        XCTAssertEqual(PeerProcess.displayName("/opt/tool/1.0/bin/2.0"), "tool 2.0")
        XCTAssertEqual(PeerProcess.displayName("/1/2"), "2")
    }
}
