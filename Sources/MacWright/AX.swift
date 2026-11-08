// Accessibility (AX) tree reading, queries and actions.
//
// A node's `path` is the list of AXChildren indexes from the application element, so a path from
// ax_tree / ax_find can be passed straight back to ax_press / ax_set_value / ax_focus.
import AppKit
import ApplicationServices
import Foundation
import MCP
import MacWrightCore

struct AXQuery {
    var role: String?
    var subrole: String?
    var title: String?
    var titleContains: String?
    var identifier: String?
    var value: String?

    init(_ a: Args) throws {
        role = try a.string("role"); subrole = try a.string("subrole"); title = try a.string("title")
        titleContains = try a.string("titleContains"); identifier = try a.string("identifier"); value = try a.string("value")
        if role == nil && subrole == nil && title == nil && titleContains == nil && identifier == nil && value == nil {
            throw ToolError("query needs at least one of role, subrole, title, titleContains, identifier, value")
        }
    }

    /// `title` / `titleContains` match the element's title or, when it has none, its description
    /// (many buttons carry their label only in AXDescription).
    func matches(_ e: AXUIElement) -> Bool {
        if let role, AX.str(e, kAXRoleAttribute) != role { return false }
        if let subrole, AX.str(e, kAXSubroleAttribute) != subrole { return false }
        if let identifier, AX.str(e, kAXIdentifierAttribute) != identifier { return false }
        let labels = [AX.str(e, kAXTitleAttribute), AX.str(e, kAXDescriptionAttribute)].compactMap { $0 }.filter { !$0.isEmpty }
        if let title, !labels.contains(title) { return false }
        if let titleContains, !labels.contains(where: { $0.localizedCaseInsensitiveContains(titleContains) }) { return false }
        if let value, AX.valueString(e) != value { return false }
        return true
    }
}

enum AX {
    static func requireTrusted() throws {
        if !AXIsProcessTrusted() { throw ToolError("MacWright has no Accessibility permission") }
    }

    static func app(_ id: String) throws -> (AXUIElement, NSRunningApplication) {
        try requireTrusted()
        let running = try Apps.running(id)
        // AX calls into MacWright's own process run on the calling thread, not the main one, and
        // pressing its status item that way kills the app (AppKit asserts). It also keeps agents
        // off MacWright's own menu (Pause, Lock, Token).
        guard running.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw ToolError("MacWright's own UI can't be driven through its tools")
        }
        let e = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(e, 3)
        return (e, running)
    }

    static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    static func str(_ e: AXUIElement, _ name: String) -> String? { attr(e, name) as? String }

    static func children(_ e: AXUIElement) -> [AXUIElement] {
        (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func valueString(_ e: AXUIElement) -> String? {
        guard let v = attr(e, kAXValueAttribute) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if CFGetTypeID(v) == AXValueGetTypeID() { return String(describing: v) }
        return nil
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    static func actions(_ e: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(e, &names)
        return (names as? [String]) ?? []
    }

    static func node(_ e: AXUIElement, path: [Int], withActions: Bool = false) -> [String: Any] {
        var n: [String: Any] = ["path": path, "role": str(e, kAXRoleAttribute) ?? ""]
        func put(_ k: String, _ v: String?) { if let v, !v.isEmpty { n[k] = v } }
        put("subrole", str(e, kAXSubroleAttribute))
        put("title", str(e, kAXTitleAttribute))
        put("description", str(e, kAXDescriptionAttribute))
        put("identifier", str(e, kAXIdentifierAttribute))
        if let v = valueString(e) { n["value"] = String(v.prefix(300)) }
        if let en = attr(e, kAXEnabledAttribute) as? Bool { n["enabled"] = en }
        if let f = attr(e, kAXFocusedAttribute) as? Bool, f { n["focused"] = true }
        if let fr = frame(e) { n["frame"] = fr }
        if withActions { n["actions"] = actions(e) }
        return n
    }

    /// Walks the tree from [root] (at [rootPath]) depth-first.
    static func walk(_ root: AXUIElement, rootPath: [Int], maxDepth: Int, skipMenuBar: Bool,
                     visit: (AXUIElement, [Int]) -> Bool) {
        func go(_ e: AXUIElement, _ path: [Int], _ depth: Int) -> Bool {
            if !visit(e, path) { return false }
            guard depth < maxDepth else { return true }
            for (i, c) in children(e).enumerated() {
                if skipMenuBar && str(c, kAXRoleAttribute) == kAXMenuBarRole { continue }
                if !go(c, path + [i], depth + 1) { return false }
            }
            return true
        }
        _ = go(root, rootPath, 0)
    }

    static func tree(app id: String, window: String?, maxDepth: Int, includeMenuBar: Bool, maxNodes: Int) throws -> [String: Any] {
        let (appEl, running) = try app(id)
        var root = appEl, rootPath: [Int] = []
        if let window {
            let kids = children(appEl)
            let windows = kids.enumerated().filter { str($0.element, kAXRoleAttribute) == kAXWindowRole }
            let pick: (offset: Int, element: AXUIElement)?
            if let idx = Int(window) { pick = idx < windows.count ? windows[idx] : nil }
            else { pick = windows.first { (str($0.element, kAXTitleAttribute) ?? "").localizedCaseInsensitiveContains(window) } }
            guard let pick else { throw ToolError("no window '\(window)' (windows: \(windows.map { str($0.element, kAXTitleAttribute) ?? "" }))") }
            root = pick.element; rootPath = [pick.offset]
        }
        // Build a nested tree.
        var count = 0
        var truncated = false
        func build(_ e: AXUIElement, _ path: [Int], _ depth: Int) -> [String: Any] {
            count += 1
            var n = node(e, path: path)
            let kids = children(e)
            if depth >= maxDepth { if !kids.isEmpty { n["childCount"] = kids.count }; return n }
            var out: [[String: Any]] = []
            for (i, c) in kids.enumerated() {
                if count >= maxNodes { truncated = true; break }
                if !includeMenuBar && str(c, kAXRoleAttribute) == kAXMenuBarRole { continue }
                out.append(build(c, path + [i], depth + 1))
            }
            if !out.isEmpty { n["children"] = out }
            return n
        }
        let t = build(root, rootPath, 0)
        return ["app": Apps.json(running), "nodeCount": count, "truncated": truncated, "tree": t]
    }

    static func find(app id: String, query: AXQuery, maxDepth: Int, limit: Int) throws -> [[String: Any]] {
        let (appEl, _) = try app(id)
        var found: [[String: Any]] = []
        walk(appEl, rootPath: [], maxDepth: maxDepth, skipMenuBar: false) { e, path in
            if query.matches(e) { found.append(node(e, path: path, withActions: true)) }
            return found.count < limit
        }
        return found
    }

    static func resolve(app id: String, path: [Int]) throws -> AXUIElement {
        var (e, _) = try app(id)
        for (depth, i) in path.enumerated() {
            let kids = children(e)
            guard i >= 0, i < kids.count else { throw ToolError("path \(path) is stale at depth \(depth) (only \(kids.count) children); re-read with ax_find") }
            e = kids[i]
        }
        return e
    }

    /// The element named by a tool call's `path` or `query`.
    static func target(_ a: Args) throws -> (AXUIElement, [Int]) {
        let id = try a.reqString("app")
        if let path = try a.ints("path") { return (try resolve(app: id, path: path), path) }
        guard let q = try a.object("query") else { throw ToolError("give path or query") }
        let (appEl, _) = try app(id)
        let query = try AXQuery(q)
        var hit: (AXUIElement, [Int])?
        walk(appEl, rootPath: [], maxDepth: try a.int("maxDepth", 14), skipMenuBar: false) { e, p in
            if query.matches(e) { hit = (e, p); return false }
            return true
        }
        guard let hit else { throw ToolError("no element matches the query") }
        return hit
    }

    static func perform(_ e: AXUIElement, _ action: String) throws {
        let r = AXUIElementPerformAction(e, action as CFString)
        guard r == .success else { throw ToolError("\(action) failed (AXError \(r.rawValue))") }
    }

    static func setValue(_ e: AXUIElement, _ v: Value) throws {
        let cf: CFTypeRef
        switch v {
        case .string(let s): cf = s as CFString
        case .bool(let b): cf = b as CFBoolean
        case .int(let i): cf = i as CFNumber
        case .double(let d): cf = d as CFNumber
        default: throw ToolError("value must be a string, number or boolean")
        }
        let r = AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, cf)
        guard r == .success else { throw ToolError("setting AXValue failed (AXError \(r.rawValue))") }
    }

    static func focus(_ e: AXUIElement) throws {
        let role = str(e, kAXRoleAttribute)
        if role == kAXWindowRole {
            AXUIElementSetAttributeValue(e, kAXMainAttribute as CFString, kCFBooleanTrue)
            try perform(e, kAXRaiseAction)
            return
        }
        let r = AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard r == .success else { throw ToolError("focusing failed (AXError \(r.rawValue))") }
    }

    // MARK: Menus

    /// Finds the child menu item titled [title] (exact, then case-insensitive contains) in [menu].
    static func menuItem(in menu: AXUIElement, _ title: String) -> AXUIElement? {
        let items = children(menu)
        let titles = items.map { str($0, kAXTitleAttribute) ?? "" }
        if let i = titles.firstIndex(of: title) { return items[i] }
        if let i = titles.firstIndex(where: { $0.localizedCaseInsensitiveContains(title) }) { return items[i] }
        return nil
    }

    static func menuTitles(_ menu: AXUIElement) -> [String] {
        children(menu).map { str($0, kAXTitleAttribute) ?? "" }.filter { !$0.isEmpty }
    }

    /// The AXMenu under [e] (a menu bar item, status item or submenu item), waiting for it to open.
    static func submenu(of e: AXUIElement, waitMs: Double) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(waitMs / 1000)
        repeat {
            if let m = children(e).first(where: { str($0, kAXRoleAttribute) == kAXMenuRole }) { return m }
            usleep(50_000)
        } while Date() < deadline
        return nil
    }

    /// Walks [itemPath] down from an open (or openable) menu and presses the last item.
    static func pick(_ itemPath: [String], from first: AXUIElement) throws -> [String: Any] {
        var menu = first
        var picked: AXUIElement?
        for (i, title) in itemPath.enumerated() {
            guard let item = menuItem(in: menu, title) else {
                cancelMenu(menu)
                throw ToolError("no menu item '\(title)' (items: \(menuTitles(menu)))")
            }
            if i == itemPath.count - 1 { picked = item; break }
            // Open the submenu: AXPress on a parent item opens it on most apps.
            if submenu(of: item, waitMs: 0) == nil { try? perform(item, kAXPressAction) }
            guard let sub = submenu(of: item, waitMs: 1000) else {
                cancelMenu(menu)
                throw ToolError("'\(title)' has no submenu")
            }
            menu = sub
        }
        guard let picked else { throw ToolError("empty itemPath") }
        if let enabled = attr(picked, kAXEnabledAttribute) as? Bool, !enabled {
            cancelMenu(menu)
            throw ToolError("menu item '\(itemPath.last!)' is disabled")
        }
        let info = node(picked, path: [])
        try perform(picked, kAXPressAction)
        return ["picked": itemPath, "item": info]
    }

    static func cancelMenu(_ menu: AXUIElement) {
        _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
    }

    static func menu(app id: String, itemPath: [String]) throws -> [String: Any] {
        guard itemPath.count >= 2 else { throw ToolError("itemPath needs a menu and an item, e.g. [\"File\", \"New Window\"]") }
        let (appEl, _) = try app(id)
        guard let bar = attr(appEl, kAXMenuBarAttribute) else { throw ToolError("app has no menu bar") }
        let barEl = bar as! AXUIElement
        guard let top = menuItem(in: barEl, itemPath[0]) else {
            throw ToolError("no menu '\(itemPath[0])' (menus: \(menuTitles(barEl)))")
        }
        try perform(top, kAXPressAction)
        guard let m = submenu(of: top, waitMs: 1000) else { throw ToolError("menu '\(itemPath[0])' did not open") }
        return try pick(Array(itemPath.dropFirst()), from: m)
    }

    /// Opens the app's menu-bar status item (AXExtrasMenuBar) and picks [itemPath] in its menu.
    /// An empty itemPath just opens the menu and lists its items.
    static func menuExtra(app id: String, index: Int, itemPath: [String], clickFallback: Bool) throws -> [String: Any] {
        let (appEl, _) = try app(id)
        guard let extras = attr(appEl, "AXExtrasMenuBar") else { throw ToolError("app has no menu-bar status item") }
        let items = children(extras as! AXUIElement)
        guard index < items.count else { throw ToolError("status item \(index) not found (app has \(items.count))") }
        let item = items[index]
        try? perform(item, kAXPressAction)
        var menu = submenu(of: item, waitMs: 800)
        if menu == nil, clickFallback, let f = frame(item) {
            // Some status items (e.g. Java AWT trays) only open on a real click.
            try Driver.shared.warp(CGPoint(x: f.midX, y: f.midY))
            try Driver.shared.click(.left, count: 1)
            menu = submenu(of: item, waitMs: 1500)
        }
        guard let menu else { throw ToolError("the status item's menu did not open") }
        if itemPath.isEmpty {
            return ["opened": true, "items": children(menu).enumerated().map { node($0.element, path: [$0.offset]) }]
        }
        return try pick(itemPath, from: menu)
    }

    // MARK: Status items

    /// Every app's menu-bar status items (AXExtrasMenuBar children), left to right. [app] narrows
    /// it to a pid, bundle id or app name. Two processes can share a name (a dev build and the
    /// packaged app): each item carries its own pid, bundleId and path.
    static func statusItems(app: String?) throws -> [(ref: StatusItemRef, element: AXUIElement, json: [String: Any])] {
        try requireTrusted()
        var out: [(ref: StatusItemRef, element: AXUIElement, json: [String: Any])] = []
        // Not MacWright's own item: see AX.app.
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited && $0.processIdentifier != me }
        let wanted = app.map { a in StatusItemPick.filter(apps.map {
            StatusItemRef(pid: $0.processIdentifier, bundleId: $0.bundleIdentifier ?? "", name: $0.localizedName ?? "", index: 0, x: 0)
        }, app: a).map(\.pid) }
        for a in apps {
            if let wanted, !wanted.contains(a.processIdentifier) { continue }
            let appEl = AXUIElementCreateApplication(a.processIdentifier)
            AXUIElementSetMessagingTimeout(appEl, 0.4)
            guard let bar = attr(appEl, "AXExtrasMenuBar") else { continue }
            for (i, item) in children(bar as! AXUIElement).enumerated() {
                let f = frame(item)
                let ref = StatusItemRef(pid: a.processIdentifier, bundleId: a.bundleIdentifier ?? "", name: a.localizedName ?? "",
                                        index: i, x: Double(f?.minX ?? 0))
                var j: [String: Any] = ["pid": Int(a.processIdentifier), "bundleId": ref.bundleId, "app": ref.name, "index": i,
                                        "path": a.bundleURL?.path ?? a.executableURL?.path ?? ""]
                if let f {
                    j["frame"] = f
                    j["center"] = CGPoint(x: f.midX, y: f.midY)
                }
                for (k, attrName) in [("title", kAXTitleAttribute), ("description", kAXDescriptionAttribute),
                                      ("help", kAXHelpAttribute), ("identifier", kAXIdentifierAttribute)] {
                    if let v = str(item, attrName), !v.isEmpty { j[k] = v }
                }
                out.append((ref, item, j))
            }
        }
        return out.sorted { $0.ref.x < $1.ref.x }
    }

    /// Clicks one status item: a real left click at its centre (default; what a popup-toggling
    /// tray icon needs), or AXPress.
    static func clickStatusItem(pid: Int32?, app: String?, index: Int, method: String, button: MouseButton) throws -> [String: Any] {
        let all = try statusItems(app: pid.map { String($0) } ?? app)
        let ref = try StatusItemPick.pick(all.map(\.ref), pid: pid, app: app, index: index)
        guard let hit = all.first(where: { $0.ref == ref }) else { throw ToolError("status item vanished") }
        switch method {
        case "press":
            try perform(hit.element, kAXPressAction)
        case "click":
            guard let f = frame(hit.element), f.width > 0, f.height > 0 else { throw ToolError("the status item has no frame to click") }
            try Driver.shared.warp(CGPoint(x: f.midX, y: f.midY))
            try Driver.shared.click(button, count: 1)
        default:
            throw ToolError("method must be click or press")
        }
        return ["item": hit.json, "method": method]
    }
}
