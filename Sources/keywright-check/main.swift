// keywright-check: run it in a terminal (or any app that hosts agents) to see whether that app
// itself holds Accessibility, Screen Recording or Input Monitoring. macOS charges a command-line
// program's permissions to the app it runs in, so if the terminal has them, an agent there can
// click, type and take screenshots without Keywright — and Keywright's lock can't stop it.
// Nothing here asks for a permission or shows a prompt; it only reads the current state.
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import IOKit.hid

struct Check {
    let name: String
    let granted: Bool
    let risk: String
    let pane: String
}

func parentPid(_ pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let pp = info.kp_eproc.e_ppid
    return pp > 0 ? pp : nil
}

func execPath(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    return String(cString: buf)
}

/// The app a process belongs to, from its executable path.
func appOf(_ path: String) -> (name: String, path: String)? {
    guard let r = path.range(of: ".app/Contents/MacOS/") else { return nil }
    let app = String(path[..<r.lowerBound]) + ".app"
    return (((app as NSString).lastPathComponent as NSString).deletingPathExtension, app)
}

/// The app macOS charges this process's permissions to. TCC uses the "responsible process", which
/// survives reparenting (a terminal's pty daemon, a detached shell), so ask for it directly
/// (libsystem's responsibility_get_pid_responsible_for_pid, macOS 10.14+). If that isn't there,
/// fall back to the outermost .app among the parent processes.
func hostApp() -> (name: String, path: String)? {
    typealias Responsible = @convention(c) (pid_t) -> pid_t
    if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") {
        let r = unsafeBitCast(sym, to: Responsible.self)(getpid())
        if r > 0, r != getpid(), let path = execPath(r) {
            return appOf(path) ?? (((path as NSString).lastPathComponent), path)
        }
    }
    var pid: pid_t? = getpid()
    var found: (name: String, path: String)?
    var hops = 0
    while let p = pid, p > 1, hops < 64 {
        if let path = execPath(p), let a = appOf(path) { found = a }
        pid = parentPid(p)
        hops += 1
    }
    return found
}

let json = CommandLine.arguments.contains("--json")
if CommandLine.arguments.contains("-h") || CommandLine.arguments.contains("--help") {
    print("""
        Usage: keywright-check [--json]

        Run this in each terminal or app where you use agents. It reports whether that app holds
        Accessibility, Screen Recording or Input Monitoring. If it does, agents there can control
        or record the Mac without Keywright, so Keywright's lock doesn't protect you.
        Exit status: 0 nothing found, 1 the app holds at least one of them.
        """)
    exit(0)
}

let checks = [
    Check(name: "Accessibility", granted: AXIsProcessTrusted() || CGPreflightPostEventAccess(),
          risk: "can click, type and press buttons in any app (for example with osascript and System Events)",
          pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
    Check(name: "Screen Recording", granted: CGPreflightScreenCaptureAccess(),
          risk: "can take screenshots and record the screen (for example with screencapture)",
          pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
    Check(name: "Input Monitoring", granted: CGPreflightListenEventAccess() || IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted,
          risk: "can read every key you type, in any app",
          pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"),
]
let host = hostApp()
let hostName = host?.name ?? "this program's host"
let bad = checks.filter(\.granted)

if json {
    let out: [String: Any] = [
        "app": host?.name ?? NSNull(), "appPath": host?.path ?? NSNull(),
        "permissions": Dictionary(uniqueKeysWithValues: checks.map { ($0.name, $0.granted) }),
        "bypassesKeywright": !bad.isEmpty,
    ]
    let d = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: d, as: UTF8.self))
    exit(bad.isEmpty ? 0 : 1)
}

let tty = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
func paint(_ s: String, _ c: String) -> String { tty ? "\u{1B}[\(c)m\(s)\u{1B}[0m" : s }

print("Checking \(paint(hostName, "1"))" + (host.map { paint("  \($0.path)", "2") } ?? ""))
for c in checks {
    print("  " + (c.granted ? paint("✗ \(c.name): granted", "31") : paint("✓ \(c.name): not granted", "32")))
}
print("")
if bad.isEmpty {
    print(paint("OK.", "32") + " Agents running in \(hostName) can only control this Mac through Keywright, so its lock applies to them.")
    exit(0)
}
print(paint("Warning:", "31;1") + " \(hostName) has " + bad.map(\.name).joined(separator: ", ") + ".")
print("Any agent running in it, Keywright locked or not:")
for c in bad { print("  - \(c.risk)") }
print("")
print("To close this, turn \(hostName) off in System Settings → Privacy & Security under each of those,")
print("then quit and reopen \(hostName). Open the panes with:")
for c in bad { print("  open \"\(c.pane)\"") }
exit(1)
