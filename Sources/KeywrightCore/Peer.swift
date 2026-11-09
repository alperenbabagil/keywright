// Which process is on the other end of a localhost TCP connection: the client's socket has
// local port = the connection's remote port and foreign port = the server's port. Only processes
// of the same user are visible (libproc refuses others), which covers every local agent.
import Darwin
import Foundation

public struct PeerProcess: Equatable, Sendable {
    public let pid: Int32
    public let path: String
    /// A readable program name. Some tools install versioned binaries
    /// (`~/.local/share/claude/versions/2.1.319`), so a name that starts with a digit is replaced by
    /// the nearest folder above it that doesn't, plus the version: "claude 2.1.319".
    public var name: String { Self.displayName(path) }

    public static func displayName(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard let last = parts.last else { return path }
        guard last.first?.isNumber == true else { return last }
        let skip: Set<String> = ["versions", "version", "bin", "libexec", "current"]
        for p in parts.dropLast().reversed() where !skip.contains(p.lowercased()) && p.first?.isNumber != true {
            return "\(p) \(last)"
        }
        return last
    }
    public init(pid: Int32, path: String) { self.pid = pid; self.path = path }
}

public enum Peer {
    /// The process holding a TCP socket from [clientPort] to [serverPort] on this Mac, or nil.
    public static func find(clientPort: UInt16, serverPort: UInt16) -> PeerProcess? {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let me = getpid()
        for pid in pids.prefix(Int(max(0, got))) where pid > 0 && pid != me {
            if holdsSocket(pid: pid, clientPort: clientPort, serverPort: serverPort) {
                return PeerProcess(pid: pid, path: path(of: pid) ?? "?")
            }
        }
        // Our own process last (tests connect to themselves).
        if holdsSocket(pid: me, clientPort: clientPort, serverPort: serverPort) {
            return PeerProcess(pid: me, path: path(of: me) ?? "?")
        }
        return nil
    }

    /// The app macOS holds responsible for [pid] (a terminal for a CLI agent), e.g. "Terminalo".
    public static func responsibleApp(of pid: pid_t) -> String? {
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        let r = unsafeBitCast(sym, to: Responsible.self)(pid)
        guard r > 0, r != pid, let p = path(of: r) else { return nil }
        if let range = p.range(of: ".app/Contents/MacOS/") {
            return ((String(p[..<range.lowerBound]) as NSString).lastPathComponent)
        }
        return (p as NSString).lastPathComponent
    }

    public static func path(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    static func holdsSocket(pid: pid_t, clientPort: UInt16, serverPort: UInt16) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        let count = Int(size) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count + 16)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        guard used > 0 else { return false }
        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard r == Int32(MemoryLayout<socket_fdinfo>.size), info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let ini = info.psi.soi_proto.pri_tcp.tcpsi_ini
            // Ports are stored in network byte order in the low 16 bits.
            let l = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
            let f = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport))
            if l == clientPort && f == serverPort { return true }
        }
        return false
    }
}
