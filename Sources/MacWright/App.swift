// The menu-bar app: hosts the MCP server and shows permissions, the connection command,
// Pause, recent tool calls and Launch at login.
//
// It starts locked: the MCP server doesn't listen until a human unlocks it with Touch ID or the
// Mac's login password. Anything can launch the app (`open`, a script, an agent), so launching
// alone must never hand out MacWright's Accessibility / Screen Recording grants.
import AppKit
import LocalAuthentication
import MacWrightCore
import ServiceManagement
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    nonisolated static let version = "1.2.0"
    nonisolated static var port: UInt16 {
        let p = UserDefaults.standard.integer(forKey: "port")
        return p > 0 && p < 65536 ? UInt16(p) : 47615
    }
    nonisolated static var serverAddress: String { "http://127.0.0.1:\(port)/mcp" }

    @Published var paused = false
    @Published var busy = false
    @Published var recent: [CallRecord] = []
    @Published var permissions: [Permission: Bool] = [:]
    @Published var serverError: String?
    @Published var locked = true
    @Published var unlocking = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var token = TokenStore.loadOrCreate()

    nonisolated(unsafe) private static var currentToken = ""
    private var host: MCPHTTPHost?
    private var timer: Timer?
    private var activity: NSObjectProtocol?

    var claudeCommand: String {
        "claude mcp add --transport http macwright \(Self.serverAddress) --header \"Authorization: Bearer \(token)\""
    }

    /// Shell command that runs the bundled permission check in whatever terminal it is pasted into.
    var checkCommand: String {
        let path = Bundle.main.resourceURL?.appendingPathComponent("macwright-check").path
            ?? "/Applications/MacWright.app/Contents/Resources/macwright-check"
        return "'\(path)'"
    }

    func start() {
        Self.currentToken = token
        Control.shared.onChange = { [weak self] in self?.syncControl() }
        refreshPermissions()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in AppState.shared.refreshPermissions() }
        }
        Hotkey.register { AppState.shared.togglePause() }
        unlock()
        // Event taps must be serviced promptly; keep App Nap from throttling this menu-bar app.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                         reason: "MacWright services event taps for tool calls")
        DispatchQueue.global(qos: .userInitiated).async {
            if !HumanInput.shared.ensureStarted() { Log.write("human-input monitor not started yet (Input Monitoring?)") }
        }
    }

    func startServer() {
        let host = MCPHTTPHost(port: Self.port, token: { AppState.currentToken }, serverFactory: { await Tools.makeServer() })
        host.onRequest = { method, path, status in
            if status >= 400 { Log.write("http \(method) \(path) → \(status)") }
        }
        do {
            try host.start()
            self.host = host
            serverError = nil
            Log.write("MCP server listening on \(Self.serverAddress)")
        } catch {
            serverError = "Could not listen on 127.0.0.1:\(Self.port): \(error)"
            Log.write(serverError!)
        }
    }

    /// Asks the human for Touch ID or the login password, then starts the server.
    func unlock() {
        guard locked, !unlocking else { return }
        unlocking = true
        NSApp.activate(ignoringOtherApps: true)
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Keep locked"
        Task { @MainActor in
            defer { unlocking = false }
            do {
                guard try await ctx.evaluatePolicy(.deviceOwnerAuthentication,
                                                   localizedReason: "start the MacWright server, which lets agents control this Mac") else { return }
                locked = false
                Control.shared.setLocked(false)
                Log.write("unlocked by the owner")
                startServer()
            } catch {
                Log.write("unlock refused: \(error.localizedDescription)")
            }
        }
    }

    /// Stops the server; it needs a new unlock to start again.
    func lock() {
        guard !locked else { return }
        // First, so a call that is running right now stops at its next check.
        Control.shared.setLocked(true)
        _ = FocusWatch.shared.stop()
        Driver.shared.releaseAll()
        host?.stop()
        host = nil
        serverError = nil
        locked = true
        Log.write("locked: MCP server stopped")
    }

    func stop() {
        Control.shared.setLocked(true)
        Driver.shared.releaseAll()
        host?.stop()
    }

    func syncControl() {
        paused = Control.shared.paused
        busy = Control.shared.busy
        recent = Control.shared.recent
    }

    func refreshPermissions() {
        var p: [Permission: Bool] = [:]
        for perm in Permission.allCases { p[perm] = perm.granted }
        if p != permissions { permissions = p }
        let login = SMAppService.mainApp.status == .enabled
        if login != launchAtLogin { launchAtLogin = login }
    }

    func togglePause() { Control.shared.setPaused(!Control.shared.paused) }

    func regenerateToken() {
        let t = TokenStore.generate()
        TokenStore.save(t)
        token = t
        Self.currentToken = t
        Log.write("token regenerated")
    }

    func copy(_ s: String, what: String) {
        NSPasteboard.general.clearContents()
        let ok = NSPasteboard.general.setString(s, forType: .string)
        Log.write("menu: copied \(what) ok=\(ok) changeCount=\(NSPasteboard.general.changeCount)")
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.write("launch at login: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Menu-bar icon: cursor symbol, a dot while a tool runs, a pause symbol while paused.
    var icon: NSImage {
        let name = paused ? "pause.circle" : "cursorarrow.motionlines"
        let size = NSSize(width: 22, height: 18)
        let showDot = busy && !paused
        let img = NSImage(size: size, flipped: false) { rect in
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            if let s = NSImage(systemSymbolName: name, accessibilityDescription: "MacWright")?.withSymbolConfiguration(cfg) {
                let r = NSRect(x: 0, y: (rect.height - s.size.height) / 2, width: s.size.width, height: s.size.height)
                s.draw(in: r)
            }
            if showDot {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.width - 7, y: 1, width: 6, height: 6)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppState
    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        if state.locked {
            Text("🔒 Locked — the MCP server is off")
            Button(state.unlocking ? "Waiting for Touch ID or password…" : "Unlock…") { state.unlock() }
                .disabled(state.unlocking)
        } else if let err = state.serverError {
            Text("⚠️ \(err)")
        } else {
            Text("MCP server: \(AppState.serverAddress)")
        }
        if !state.locked {
            Text(state.paused ? "Paused — tool calls fail with \"paused\"" : (state.busy ? "Running a tool call…" : "Ready"))
            Button("Lock (stop the server)") { state.lock() }
        }
        Divider()
        Section("Permissions") {
            ForEach(Permission.allCases) { p in
                let ok = state.permissions[p] ?? false
                Button("\(ok ? "✅" : "❌") \(p.rawValue)\(ok ? "" : " — click to request")") { p.request() }
            }
            // Only MacWright should hold these: a terminal that does lets agents skip the lock.
            Button("Copy terminal check command") { state.copy(state.checkCommand, what: "terminal check command") }
        }
        Divider()
        Button("Copy Claude Code command") { state.copy(state.claudeCommand, what: "Claude Code command") }
        Menu("Token") {
            Text(state.token)
            Button("Copy token") { state.copy(state.token, what: "token") }
            Button("Regenerate token") { state.regenerateToken() }
        }
        Divider()
        Toggle("Pause  (⌃⌥⌘⎋)", isOn: Binding(get: { state.paused }, set: { Control.shared.setPaused($0) }))
        Menu("Recent tool calls") {
            if state.recent.isEmpty { Text("None yet") }
            ForEach(state.recent.prefix(25)) { r in
                Text("\(Self.time.string(from: r.time))  \(r.ok ? "✓" : "✗") \(r.tool)  \(r.ms) ms\(r.ok ? "" : " — \(r.note.prefix(60))")")
            }
            Divider()
            Button("Clear") { Control.shared.clearRecent() }
            Button("Open log") { NSWorkspace.shared.open(Log.url) }
        }
        Toggle("Launch at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
        Divider()
        Button("Quit MacWright") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in AppState.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.stop() }
    }
}

struct MacWrightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(nsImage: state.icon)
        }
    }
}
