// Windows (CGWindowList), apps (NSWorkspace) and the clipboard (NSPasteboard).
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MacWrightCore

enum Windows {
    /// Processes that draw system prompts a test cannot answer itself: TCC permission alerts,
    /// Gatekeeper, authentication and keychain dialogs, notification-center alerts.
    static let promptOwners: Set<String> = [
        "UserNotificationCenter", "SecurityAgent", "CoreServicesUIAgent", "universalAccessAuthWarn",
        "coreautha", "tccd", "TCC", "ScreenCaptureKit", "SystemUIServer Alert", "Keychain Access",
        "Notification Center",
    ]

    static func isPrompt(owner: String, layer: Int, title: String) -> Bool {
        if promptOwners.contains(owner) { return owner != "Notification Center" || layer > 0 && !title.isEmpty }
        return false
    }

    /// What Notification Center is actually showing. Its full-display window (layer 21, title
    /// "Notification Center") stays around — and CGWindowList can call it on screen — while
    /// nothing is visible, so the window alone means nothing; its AX tree has content only while a
    /// banner/alert is up or the panel is open. nil when AX is unavailable (then the window rule
    /// applies, as before).
    static func notificationCenterContent(pid: Int) -> (visible: Bool, info: [String: Any])? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid_t(pid))
        AXUIElementSetMessagingTimeout(app, 0.5)
        var nodes: [AXLite] = []
        AX.walk(app, rootPath: [], maxDepth: 12, skipMenuBar: true) { e, _ in
            let f = AX.frame(e) ?? .zero
            let label = [AX.str(e, kAXDescriptionAttribute), AX.str(e, kAXTitleAttribute), AX.valueString(e)]
                .compactMap { $0 }.first { !$0.isEmpty } ?? ""
            nodes.append(AXLite(role: AX.str(e, kAXRoleAttribute) ?? "", subrole: AX.str(e, kAXSubroleAttribute) ?? "",
                                width: Double(f.width), height: Double(f.height), label: String(label.prefix(200))))
            return nodes.count < 400
        }
        let c = NotificationCenterRule.content(nodes)
        var info: [String: Any] = ["visible": c.visible]
        if !c.banners.isEmpty { info["banners"] = c.banners }
        if !c.alerts.isEmpty { info["alerts"] = c.alerts }
        if c.other > 0 { info["otherElements"] = c.other }
        return (c.visible, info)
    }

    static func list(app: String?, includeOffscreen: Bool) -> [[String: Any]] {
        let opts: CGWindowListOption = includeOffscreen ? [.optionAll, .excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements]
        let raw = (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []
        var bundleByPid: [Int: String] = [:]
        var ncByPid: [Int: (visible: Bool, info: [String: Any])?] = [:]
        return raw.compactMap { w in
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
            if bundleByPid[pid] == nil {
                bundleByPid[pid] = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier ?? ""
            }
            let bundle = bundleByPid[pid] ?? ""
            if let app, !app.isEmpty, bundle != app, !owner.localizedCaseInsensitiveContains(app) { return nil }
            let title = w[kCGWindowName as String] as? String ?? ""
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            var bounds = CGRect.zero
            if let b = w[kCGWindowBounds as String] as? NSDictionary { bounds = CGRect(dictionaryRepresentation: b) ?? .zero }
            let onScreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
            var prompt = isPrompt(owner: owner, layer: layer, title: title)
            var o: [String: Any] = [
                "id": w[kCGWindowNumber as String] as? Int ?? 0, "owner": owner, "pid": pid, "bundleId": bundle,
                "title": title, "bounds": bounds, "layer": layer, "onScreen": onScreen, "alpha": alpha,
            ]
            if bundle == "com.apple.notificationcenterui" || owner == "Notification Center" {
                if ncByPid[pid] == nil { ncByPid[pid] = notificationCenterContent(pid: pid) }
                if let nc = ncByPid[pid] ?? nil {
                    // Showing something only while on screen, opaque and with AX content.
                    prompt = onScreen && alpha > 0 && nc.visible
                    o["notificationCenter"] = nc.info
                    if prompt { o["promptKind"] = (nc.info["alerts"] != nil) ? "notificationAlert" : (nc.info["banners"] != nil ? "notificationBanner" : "notificationCenterOpen") }
                } else {
                    prompt = prompt && onScreen && alpha > 0
                }
            }
            o["systemPrompt"] = prompt
            return o
        }
    }
}

enum Apps {
    static func running(_ bundleId: String) throws -> NSRunningApplication {
        if let a = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first { return a }
        if let pid = Int32(bundleId), let a = NSRunningApplication(processIdentifier: pid) { return a }
        if let a = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.caseInsensitiveCompare(bundleId) == .orderedSame }) {
            return a
        }
        throw ToolError("app '\(bundleId)' is not running")
    }

    static func json(_ a: NSRunningApplication) -> [String: Any] {
        let policy: String
        switch a.activationPolicy {
        case .regular: policy = "regular"
        case .accessory: policy = "accessory"
        default: policy = "prohibited"
        }
        return ["name": a.localizedName ?? "", "bundleId": a.bundleIdentifier ?? "", "pid": Int(a.processIdentifier),
                "active": a.isActive, "hidden": a.isHidden, "policy": policy, "path": a.bundleURL?.path ?? ""]
    }

    static func list(includeBackground: Bool) -> [[String: Any]] {
        NSWorkspace.shared.runningApplications
            .filter { includeBackground || $0.activationPolicy != .prohibited }
            .map(json)
    }

    static func launch(bundleId: String?, path: String?, args: [String], activate: Bool) throws -> [String: Any] {
        let url: URL
        if let path { url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        else if let bundleId, let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) { url = u }
        else { throw ToolError("app not found: give bundleId of an installed app or path") }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.arguments = args
        cfg.activates = activate
        let app = try blocking { try await NSWorkspace.shared.openApplication(at: url, configuration: cfg) }
        return json(app)
    }

    static func quit(_ bundleId: String, force: Bool, timeoutMs: Double) throws -> [String: Any] {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        if apps.isEmpty { return ["bundleId": bundleId, "wasRunning": false, "terminated": true] }
        for a in apps { _ = force ? a.forceTerminate() : a.terminate() }
        let deadline = Date().addingTimeInterval(timeoutMs / 1000)
        while Date() < deadline, apps.contains(where: { !$0.isTerminated }) { usleep(100_000) }
        return ["bundleId": bundleId, "wasRunning": true, "terminated": apps.allSatisfy(\.isTerminated)]
    }

    static func activate(_ bundleId: String) throws -> [String: Any] {
        let a = try running(bundleId)
        let ok = DispatchQueue.main.sync { a.activate(options: [.activateAllWindows]) }
        usleep(150_000)
        return ["activated": ok, "app": json(a)]
    }

    static func open(_ url: URL, with bundleId: String?) throws -> [String: Any] {
        let cfg = NSWorkspace.OpenConfiguration()
        if let bundleId {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
                throw ToolError("no app with bundle id \(bundleId)")
            }
            let app = try blocking { try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg) }
            return ["opened": url.absoluteString, "app": json(app)]
        }
        let ok = NSWorkspace.shared.open(url)
        return ["opened": url.absoluteString, "ok": ok]
    }
}

enum Clipboard {
    static func get(types: [String]?) -> [String: Any] {
        let pb = NSPasteboard.general
        var out: [String: Any] = [
            "changeCount": pb.changeCount,
            "types": (pb.types ?? []).map(\.rawValue),
            "string": pb.string(forType: .string) as Any? ?? NSNull(),
        ]
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        out["fileUrls"] = urls.map(\.path)
        if let types {
            var data: [String: Any] = [:]
            for t in types {
                guard let d = pb.data(forType: NSPasteboard.PasteboardType(t)) else { data[t] = NSNull(); continue }
                if let s = String(data: d, encoding: .utf8) { data[t] = ["text": String(s.prefix(100_000))] }
                else { data[t] = ["base64": d.prefix(1_000_000).base64EncodedString(), "bytes": d.count] }
            }
            out["data"] = data
        }
        return out
    }

    static func set(text: String?, files: [String]?) throws -> [String: Any] {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let files, !files.isEmpty {
            let urls = files.map { NSURL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            guard pb.writeObjects(urls) else { throw ToolError("could not write file URLs to the clipboard") }
        } else if let text {
            guard pb.setString(text, forType: .string) else { throw ToolError("could not write text to the clipboard") }
        } else {
            throw ToolError("give text or fileUrls")
        }
        return ["changeCount": pb.changeCount]
    }
}

/// Opens Chrome with a profile, URLs, a new / incognito / app window, or a debugging port. The
/// command line goes to a fresh Chrome process (`open -na` style), which hands it to the running
/// Chrome for that user data dir, so it works whether Chrome is running or not.
enum ChromeApp {
    static func userDataDir(_ channel: ChromeChannel, override: String?) -> String {
        if let override { return (override as NSString).expandingTildeInPath }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(channel.userDataSubpath).path
    }

    static func localState(_ dir: String) throws -> Chrome.LocalState {
        let path = (dir as NSString).appendingPathComponent("Local State")
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ToolError("can't read \(path): is this channel installed and has it run once?")
        }
        return try Chrome.parseLocalState(data)
    }

    static func profiles(channel: ChromeChannel, userDataDir override: String?) throws -> [String: Any] {
        let dir = userDataDir(channel, override: override)
        let s = try localState(dir)
        return ["channel": channel.rawValue, "bundleId": channel.bundleId, "userDataDir": dir,
                "lastUsed": s.lastUsed as Any? ?? NSNull(), "profiles": s.profiles.map(\.json),
                "running": !NSRunningApplication.runningApplications(withBundleIdentifier: channel.bundleId).isEmpty]
    }

    /// Normal-layer windows of the bundle, by id.
    static func windowIds(_ bundleId: String) -> Set<Int> {
        Set(Windows.list(app: bundleId, includeOffscreen: false)
            .filter { $0["bundleId"] as? String == bundleId && $0["layer"] as? Int == 0 }
            .compactMap { $0["id"] as? Int })
    }

    static func open(channel: ChromeChannel, profile: String?, userDataDir override: String?, options base: Chrome.Options,
                     activate: Bool, timeoutMs: Double) throws -> [String: Any] {
        let bundleId = channel.bundleId
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            throw ToolError("\(bundleId) is not installed")
        }
        var o = base
        var resolved: ChromeProfile?
        if let profile {
            if base.guest { throw ToolError("guest mode has no profile; drop profile or guest") }
            resolved = try Chrome.resolve(profile, in: localState(userDataDir(channel, override: override)).profiles)
            o.profileDirectory = resolved!.directory
        }
        if let override { o.userDataDir = (override as NSString).expandingTildeInPath }
        let args = try Chrome.arguments(o)

        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
        let before = windowIds(bundleId)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.arguments = args
        cfg.activates = activate
        // A new instance carries the arguments; a running Chrome would otherwise just be activated.
        cfg.createsNewApplicationInstance = wasRunning
        _ = try blocking { try await NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) }

        // A tab in an existing window makes no new window; everything else should.
        let expectWindow = !wasRunning || o.newWindow || o.incognito || o.guest || o.appURL != nil
        let deadline = Date().addingTimeInterval((expectWindow ? timeoutMs : min(timeoutMs, 500)) / 1000)
        var fresh: Set<Int> = []
        repeat {
            usleep(100_000)
            fresh = windowIds(bundleId).subtracting(before)
        } while fresh.isEmpty && Date() < deadline

        let main = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .min { $0.launchDate ?? .distantPast < $1.launchDate ?? .distantPast }
        let windows = Windows.list(app: bundleId, includeOffscreen: false)
            .filter { $0["bundleId"] as? String == bundleId && $0["layer"] as? Int == 0 }
        var out: [String: Any] = [
            "channel": channel.rawValue, "arguments": args, "wasRunning": wasRunning,
            "profile": resolved?.json as Any? ?? NSNull(),
            "newWindowIds": fresh.sorted(), "windows": windows,
            "app": main.map(Apps.json) as Any? ?? NSNull(),
        ]
        if expectWindow && fresh.isEmpty { out["warning"] = "no new Chrome window appeared within \(Int(timeoutMs)) ms" }
        return out
    }
}
