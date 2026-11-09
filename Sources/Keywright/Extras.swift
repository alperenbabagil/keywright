// Helpers for end-to-end runs:
// which app gets posted keys, a guard against typing into the agent's own terminal, a log-line
// trigger, real-click menu picks, and drags that dwell at an edge.
import AppKit
import Carbon
import Foundation
import KeywrightCore

enum Focus {
    /// The app that gets posted keys: NSWorkspace's frontmost application (System Events'
    /// "frontmost process" disagreed with it in a live run).
    static func activeApp() -> NSRunningApplication? { NSWorkspace.shared.frontmostApplication }

    static func activeJSON() -> [String: Any] {
        guard let a = activeApp() else { return [:] }
        return ["bundleId": a.bundleIdentifier ?? "", "name": a.localizedName ?? "", "pid": Int(a.processIdentifier)]
    }

    /// Apps keys are never posted to unless asked: terminals that may host the agent driving
    /// Keywright, where an Esc cancels the agent's own tool call. Override with
    /// `defaults write com.kuarasoft.keywright refuseKeysTo -array <bundle ids>` (an empty array turns it off).
    static let builtInRefuse = ["io.github.alperenbabagil.terminalo", "com.apple.Terminal", "com.googlecode.iterm2",
                                "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
                                "com.github.wez.wezterm", "co.zeit.hyper", "com.microsoft.VSCode"]

    static var refuseList: [String] { LaunchSettings.refuseKeysTo ?? builtInRefuse }

    /// Throws (nothing posted) when the keys would reach the wrong app. While the cursor is hidden
    /// (an app has captured the mouse) its HID tap takes every key first, so only keyTarget is checked then.
    static func requireKeyTarget(_ a: Args) throws {
        let active = activeApp()
        let bundle = active?.bundleIdentifier ?? ""
        let name = active?.localizedName ?? "?"
        if let target = try a.string("keyTarget"), !target.isEmpty {
            let matches = bundle == target || (active?.localizedName ?? "") == target || String(active?.processIdentifier ?? -1) == target
            if !matches {
                throw ToolError("keyTarget \(target) is not the active app (active: \(name) \(bundle)); nothing posted. Use activate_app first.")
            }
            return
        }
        if try a.bool("allowActive", false) || cursorHidden() { return }
        let refuse = try a.strings("refuseIfActive") ?? refuseList
        if refuse.contains(bundle) {
            throw ToolError("refused: \(name) (\(bundle)) is the active app, so these keys would go to it — it may be the terminal running this agent, where Esc cancels the tool call. Bring the target app forward with activate_app, pass keyTarget, or allowActive: true. Nothing posted.")
        }
    }
}

/// `when: {file, regex, timeoutMs}`: block until a new line of [file] matches [regex], then let the
/// tool act. Only lines written after the call started count.
enum LogTrigger {
    static func wait(_ w: Args) throws -> [String: Any] {
        let path = (try w.reqString("file") as NSString).expandingTildeInPath
        let pattern = try w.reqString("regex")
        let timeout = try w.double("timeoutMs", 30_000)
        guard let re = try? NSRegularExpression(pattern: pattern) else { throw ToolError("when.regex is not a valid regular expression") }
        guard let fh = FileHandle(forReadingAtPath: path) else { throw ToolError("when.file can't be read: \(path)") }
        defer { try? fh.close() }
        var offset = (try? fh.seekToEnd()) ?? 0
        let t0 = Date()
        var pending = ""
        while true {
            try Control.shared.checkPaused()
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? offset
            if size < offset { offset = 0 }  // rotated or truncated: read from the start
            if size > offset {
                try? fh.seek(toOffset: offset)
                let data = fh.readDataToEndOfFile()
                offset += UInt64(data.count)
                pending += String(decoding: data, as: UTF8.self)
                var lines = pending.components(separatedBy: "\n")
                pending = lines.removeLast()
                for line in lines {
                    let r = NSRange(line.startIndex..., in: line)
                    if re.firstMatch(in: line, range: r) != nil {
                        return ["matched": line, "waitedMs": Int(Date().timeIntervalSince(t0) * 1000)]
                    }
                }
            }
            if Date().timeIntervalSince(t0) * 1000 >= timeout {
                throw ToolError("when: no new line in \(path) matched /\(pattern)/ within \(Int(timeout)) ms; nothing posted")
            }
            usleep(2000)
        }
    }
}

extension AX {
    /// menu_extra with real clicks: click the status item, wait until the menu items have frames,
    /// hover parents to open submenus, click the last item's centre. A real click counts as a user
    /// action, so an app may activate itself in response (AXPress does not).
    static func menuExtraClick(app id: String, index: Int, itemPath: [String]) throws -> [String: Any] {
        let (appEl, _) = try app(id)
        guard let extras = attr(appEl, "AXExtrasMenuBar") else { throw ToolError("app has no menu-bar status item") }
        let items = children(extras as! AXUIElement)
        guard index < items.count else { throw ToolError("status item \(index) not found (app has \(items.count))") }
        let item = items[index]
        guard let f = frame(item) else { throw ToolError("the status item has no frame") }
        try Driver.shared.warp(CGPoint(x: f.midX, y: f.midY))
        try Driver.shared.click(.left, count: 1)
        guard var menu = submenu(of: item, waitMs: 1500) else { throw ToolError("the status item's menu did not open") }
        if itemPath.isEmpty {
            return ["opened": true, "method": "click", "items": children(menu).enumerated().map { node($0.element, path: [$0.offset]) }]
        }
        for (i, title) in itemPath.enumerated() {
            guard let it = menuItem(in: menu, title) else {
                cancelMenu(menu)
                throw ToolError("no menu item '\(title)' (items: \(menuTitles(menu)))")
            }
            // Items have zero frames until the menu is drawn. The AX menu exists even while closed, so if the
            // first click didn't open it (2026-11-04, right after the app relaunched) click the status item again.
            var deadline = Date().addingTimeInterval(1.5)
            var r = frame(it)
            var reclicked = false
            while (r == nil || r!.width < 1) && Date() < deadline {
                usleep(30_000); r = frame(it)
                if i == 0, !reclicked, (r == nil || r!.width < 1), Date().addingTimeInterval(0.8) > deadline {
                    reclicked = true
                    try Driver.shared.warp(CGPoint(x: f.midX, y: f.midY))
                    try Driver.shared.click(.left, count: 1)
                    deadline = Date().addingTimeInterval(1.5)
                }
            }
            guard let r, r.width >= 1 else { cancelMenu(menu); throw ToolError("menu item '\(title)' never got a frame") }
            let center = CGPoint(x: r.midX, y: r.midY)
            if i == itemPath.count - 1 {
                if let enabled = attr(it, kAXEnabledAttribute) as? Bool, !enabled {
                    cancelMenu(menu)
                    throw ToolError("menu item '\(title)' is disabled")
                }
                let info = node(it, path: [])
                let before = Focus.activeApp()?.processIdentifier
                try Driver.shared.warp(center)
                usleep(60_000)
                try Driver.shared.click(.left, count: 1)
                // An app that activates in response does so after it has built its window: 300 ms
                // was too soon for some apps' windows. Wait up to 1.5 s.
                let t0 = Date()
                usleep(150_000)
                while Focus.activeApp()?.processIdentifier == before && Date().timeIntervalSince(t0) < 1.5 { usleep(50_000) }
                return ["picked": itemPath, "item": info, "method": "click", "activeAfter": Focus.activeJSON(),
                        "activeChanged": Focus.activeApp()?.processIdentifier != before]
            }
            // Hovering a parent item opens its submenu.
            try Driver.shared.warp(center)
            try Driver.shared.moveBy([CGVector(dx: 1, dy: 0), CGVector(dx: -1, dy: 0)], intervalMs: 20)
            guard let sub = submenu(of: it, waitMs: 1200) else { cancelMenu(menu); throw ToolError("'\(title)' has no submenu") }
            menu = sub
        }
        throw ToolError("empty itemPath")
    }
}

extension Tools {
    /// drag with toEdge: from the current spot glide to the edge of the display under the cursor
    /// (or `display`), wait dwellMs, keep nudging outward, hold, then release — what a user dragging
    /// files onto a screen edge does. Edge-dwell detectors often count only motion after a pause at the edge.
    static func dragToEdge(_ a: Args, edge: Edge) throws -> [String: Any] {
        let b = try MouseButton.parse(try a.string("button"))
        let pressed = !Driver.shared.isHeld(b)
        if pressed { try Driver.shared.down(b); usleep(30_000) }
        let release = try a.bool("release", true)
        defer { if release && (pressed || Driver.shared.isHeld(b)) { Driver.shared.up(b) } }
        Driver.shared.sync()
        let start = Driver.shared.pos
        let disp = try a.int("display") != nil ? try Displays.find(try a.int("display")) : (Displays.under(start) ?? (try Displays.find(nil)))
        let bounds = disp.bounds
        let target: CGPoint
        switch edge {
        case .left: target = CGPoint(x: bounds.minX, y: start.y)
        case .right: target = CGPoint(x: bounds.maxX - 1, y: start.y)
        case .top: target = CGPoint(x: start.x, y: bounds.minY)
        case .bottom: target = CGPoint(x: start.x, y: bounds.maxY - 1)
        }
        let dx = target.x - start.x, dy = target.y - start.y
        let n = max(1, Int((max(abs(dx), abs(dy)) / 20).rounded(.up)))
        try Driver.shared.moveBy(Array(repeating: CGVector(dx: dx / Double(n), dy: dy / Double(n)), count: n),
                                 intervalMs: try a.double("intervalMs", 12))
        try Driver.shared.settle(at: target)
        let atEdge = Driver.shared.pos
        let dwell = try a.double("dwellMs", 0)
        if dwell > 0 { sleepMs(dwell); try Control.shared.checkPaused() }
        let out: CGVector
        switch edge {
        case .left: out = CGVector(dx: -3, dy: 0)
        case .right: out = CGVector(dx: 3, dy: 0)
        case .top: out = CGVector(dx: 0, dy: -3)
        case .bottom: out = CGVector(dx: 0, dy: 3)
        }
        let pushes = max(0, try a.int("pushSteps", dwell > 0 ? 8 : 0))
        if pushes > 0 { try Driver.shared.moveBy(Array(repeating: out, count: pushes), intervalMs: 15) }
        let hold = try a.double("holdMs", 0)
        if hold > 0 { sleepMs(hold); try Control.shared.checkPaused() }
        return ["autoPressed": pressed, "released": release, "edge": edge.rawValue, "display": Int(disp.id),
                "start": start, "positionAtEdge": atEdge,
                "reachedEdge": abs(atEdge.x - target.x) < 1 && abs(atEdge.y - target.y) < 1]
    }

    /// Tools a chord step may run.
    static let chordSteps: Set<String> = ["push_edge", "move", "move_to", "drag", "key", "type_text", "click", "scroll", "warp", "down", "up"]

    /// chord: hold modifiers while running a few steps in one call, e.g. ⌘ through a push, a Tab
    /// and a pause; the modifiers come up at the end or at a release step.
    static func chord(_ a: Args) throws -> [String: Any] {
        let held = try (a.strings("hold") ?? []).map { try KeyMap.modifier($0) }
        guard case .array(let steps)? = a.raw["steps"] else { throw ToolError("'steps' must be an array") }
        var stillHeld = held
        try Driver.shared.pressModifiers(held)
        defer { Driver.shared.releaseModifiers(stillHeld) }
        var done: [[String: Any]] = []
        for (i, s) in steps.enumerated() {
            guard case .object(let o) = s, o.count == 1, let (name, v) = o.first else {
                throw ToolError("step \(i) must be an object with exactly one key (a tool name, sleepMs or release)")
            }
            switch name {
            case "sleepMs":
                let ms = try Args(["ms": v]).double("ms", 0)
                sleepMs(min(60_000, ms))
                try Control.shared.checkPaused()
                done.append(["sleepMs": ms])
            case "release":
                let mods = try Args(["m": v]).strings("m").map { try $0.map { try KeyMap.modifier($0) } } ?? stillHeld
                Driver.shared.releaseModifiers(mods)
                stillHeld.removeAll { mods.contains($0) }
                done.append(["released": mods.map(\.rawValue)])
            default:
                guard chordSteps.contains(name), let def = byName[name] else {
                    throw ToolError("step \(i): '\(name)' can't run in a chord (allowed: \(chordSteps.sorted().joined(separator: ", ")), sleepMs, release)")
                }
                guard case .object(let sub) = v else { throw ToolError("step \(i): '\(name)' needs an object of arguments") }
                let args = Args(sub)
                // A step's own `when` gates it (callSync handles only the top level): a ⌘Tab that
                // waits for the app's "captured" state must not go to the Mac when the jump didn't happen.
                var whenInfo: [String: Any]?
                if let w = try args.object("when") {
                    do { whenInfo = try LogTrigger.wait(w) } catch { throw ToolError("step \(i) (\(name)): \(error)") }
                }
                // Keys go to whoever is active now, which an earlier step (⌘Tab) may have changed.
                if Tools.keyTools.contains(name) {
                    try Focus.requireKeyTarget(Args(a.raw.merging(sub) { _, step in step }))
                }
                let r = try def.run(args)
                var out: [String: Any] = r.json
                if let whenInfo { out["when"] = whenInfo }
                done.append([name: out.isEmpty ? true : out])
            }
        }
        return ["held": held.map(\.rawValue), "steps": done]
    }
}

/// CGGetEventTapList: who taps what, and how slowly (event_taps).
enum EventTaps {
    static func list(filter: String?) -> [[String: Any]] {
        var n: UInt32 = 0
        guard CGGetEventTapList(0, nil, &n) == .success, n > 0 else { return [] }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(n))
        guard CGGetEventTapList(n, &taps, &n) == .success else { return [] }
        return taps.prefix(Int(n)).compactMap { t in
            let app = NSRunningApplication(processIdentifier: t.tappingProcess)
            let name = app?.localizedName ?? procName(t.tappingProcess)
            if let f = filter, !f.isEmpty, String(t.tappingProcess) != f, !name.localizedCaseInsensitiveContains(f) { return nil }
            let loc = ["hid", "session", "annotatedSession"]
            return ["id": Int(t.eventTapID), "pid": Int(t.tappingProcess), "process": name,
                    "location": Int(t.tapPoint.rawValue) < loc.count ? loc[Int(t.tapPoint.rawValue)] : "\(t.tapPoint.rawValue)",
                    "mode": t.options == .listenOnly ? "listen" : "active", "enabled": t.enabled,
                    "mask": String(format: "0x%llx", t.eventsOfInterest),
                    "latencyMs": ["min": Double(t.minUsecLatency) / 1000, "avg": Double(t.avgUsecLatency) / 1000, "max": Double(t.maxUsecLatency) / 1000]]
        }
    }

    private static func procName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 1024)
        return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "?"
    }
}

/// The text the current keyboard layout gives a key, as the HID system puts on a hardware key event
/// (CGEventKeyboardGetUnicodeString). Apps that forward keys read it to type what the Mac would type on Turkish-Q,
/// AZERTY and the like (B41); without it Keywright's `key` events carried no text. Dead keys give their
/// spacing accent. Main thread: TIS calls want it.
enum LayoutText {
    static func text(keyCode: CGKeyCode, flags: UInt64) -> String? {
        let work = { () -> String? in
            guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let raw = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
            var carbon: UInt32 = 0
            if flags & CGEventFlags.maskShift.rawValue != 0 { carbon |= UInt32(shiftKey) }
            if flags & CGEventFlags.maskAlternate.rawValue != 0 { carbon |= UInt32(optionKey) }
            if flags & CGEventFlags.maskControl.rawValue != 0 { carbon |= UInt32(controlKey) }
            if flags & CGEventFlags.maskCommand.rawValue != 0 { carbon |= UInt32(cmdKey) }
            if flags & CGEventFlags.maskAlphaShift.rawValue != 0 { carbon |= UInt32(alphaLock) }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 8)
            var n = 0
            let status = data.withUnsafeBytes { buf -> OSStatus in
                guard let layout = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
                return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), (carbon >> 8) & 0xFF, UInt32(LMGetKbdType()),
                                      OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &n, &chars)
            }
            guard status == noErr, n > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: n)
        }
        return Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }
}
