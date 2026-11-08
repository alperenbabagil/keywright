// The MCP tool set. Every tool returns structured JSON (also as text) and, for input tools, the
// cursor position after the action. Calls run one at a time on a serial queue; a failing call
// releases every held button and key.
import AppKit
import Foundation
import MCP
import MacWrightCore

struct ToolOutput {
    var json: [String: Any]
    var image: (base64: String, mime: String)?
    init(_ json: [String: Any] = [:], image: (String, String)? = nil) {
        self.json = json
        self.image = image.map { (base64: $0.0, mime: $0.1) }
    }
}

struct ToolDef {
    let name: String
    let description: String
    let schema: Value
    /// Allowed while paused (reads nothing from the screen, posts nothing).
    var whilePaused = false
    let run: (Args) throws -> ToolOutput
}

private typealias S = Schema

private func rect(_ a: Args, _ key: String = "rect") throws -> CGRect? {
    guard let r = try a.object(key) else { return nil }
    return CGRect(x: try r.req("x"), y: try r.req("y"), width: try r.req("width"), height: try r.req("height"))
}

private func modifiers(_ a: Args, _ key: String = "modifiers") throws -> [KeyMap.Modifier] {
    try (a.strings(key) ?? []).map { try KeyMap.modifier($0) }
}

private let rectSchema: Value = ["type": "object", "description": "Rectangle in global points",
                                 "properties": ["x": ["type": "number"], "y": ["type": "number"],
                                                "width": ["type": "number"], "height": ["type": "number"]]]
private let queryProps: [String: Value] = [
    "role": S.str("AXRole, e.g. AXButton"), "subrole": S.str("AXSubrole"),
    "title": S.str("Exact title (or description when the element has no title)"),
    "titleContains": S.str("Case-insensitive substring of title or description"),
    "identifier": S.str("AXIdentifier"), "value": S.str("Exact AXValue as text"),
]
private let querySchema: Value = ["type": "object", "description": "Element query (first match is used)", "properties": .object(queryProps)]
private let modsSchema = S.strs("Modifiers: cmd, opt, ctrl, shift, fn")
private let appSchema = S.str("App bundle id (or running app name / pid)")

enum Tools {
    static let queue = DispatchQueue(label: "macwright.tools", qos: .userInitiated)

    static let all: [ToolDef] = info + mouse + keyboard + events + screen + windows + accessibility + clipboard + waiting

    /// Tools that post input: their results say what was posted, and they accept `watch` and
    /// `humanQuietMs`.
    static let inputTools: Set<String> = ["warp", "move", "drag", "move_to", "push_edge", "click", "down", "up",
                                          "force_click", "scroll", "key", "type_text", "hold", "release_all",
                                          "click_status_item", "chord"]

    /// Tools that post keys: they take keyTarget / allowActive / refuseIfActive (see Focus).
    static let keyTools: Set<String> = ["key", "type_text", "hold", "chord"]

    static let keyTargetProps: [String: Value] = [
        "keyTarget": S.str("Refuse (nothing posted) unless this app is the active one — bundle id, name or pid. The keys go to the active app."),
        "allowActive": S.bool("Post even if the active app is a terminal on the refuse list (default false). Not needed while the cursor is hidden by an app's mouse capture."),
        "refuseIfActive": S.strs("Bundle ids that must not be active (default: terminals that may host the agent, or `defaults write com.kuarasoft.macwright refuseKeysTo -array …`)"),
    ]

    /// `modifiers` held for a whole gesture (flagsChanged down first, flags on every event, up after).
    static func withModifiers<T>(_ a: Args, _ body: () throws -> T) throws -> T {
        let mods = try modifiers(a)
        try Driver.shared.pressModifiers(mods)
        defer { Driver.shared.releaseModifiers(mods) }
        return try body()
    }

    /// Default for `humanQuietMs` (`defaults write com.kuarasoft.macwright humanQuietMs -int 500`); 0 = off.
    static var defaultHumanQuietMs: Double { UserDefaults.standard.double(forKey: "humanQuietMs") }

    static let watchProps: [String: Value] = [
        "watch": ["description": .string("Record what taps actually saw during this call and return it as `observed`: true or \"session\" (session tap), \"hid\" (HID tap, where HID-level apps listen) or \"both\". The result is read after a fence event has reached every tap, so all of the call's events have had their chance to arrive; observed.complete is false (and fence.missing names the tap) when a tap never got it."),
                  "anyOf": [["type": "boolean"], ["type": "string", "enum": ["session", "hid", "both"]]]],
        "swallow": S.bool("With watch: drop MacWright's own events at the head of the HID stream after recording them, so no app receives them (delivery check without side effects). Implies the HID tap."),
        "humanQuietMs": S.num("Refuse (error, nothing posted) if human input — any mouse, trackpad, key or scroll event MacWright did not post — arrived within this many ms before the call. Default 0 (off) unless set with `defaults write com.kuarasoft.macwright humanQuietMs -int N`."),
        "when": ["type": "object", "description": "Wait until a new line of `file` (written after the call starts) matches `regex`, then act — for races like a hotkey within 1 s of a log line. Times out (error, nothing posted) after timeoutMs (default 30000). The result's `when` has the line and waitedMs.",
                 "properties": ["file": ["type": "string"], "regex": ["type": "string"], "timeoutMs": ["type": "number"]]],
    ]

    // MARK: Events

    static let events: [ToolDef] = [
        ToolDef(name: "record_events", description: "Record raw input for `seconds` with listen-only taps at kCGHIDEventTap and kCGSessionEventTap: type, flags, location, every non-zero integer and double CGEventField 0-255, and the NSEvent view (type, stage, pressure, phase…). Saves everything to a JSON file and returns a summary plus the matching events. Use it to capture a real gesture (e.g. a trackpad force click) and compare it with MacWright's synthetic one. Records keystrokes too — only run it while you're the one typing.",
                schema: S.object(["seconds": S.num("How long to record (max 120)"),
                                  "types": S.strs("Only return these event types (names like gesture, keyDown, leftMouseDown, or numbers); the file always has everything"),
                                  "taps": S.strs("hid and/or session (default both)"),
                                  "path": S.str("Where to save the JSON (default ~/Library/Caches/MacWright/recordings/)")],
                                 required: ["seconds"])) { a in
            ToolOutput(try Recording.record(seconds: min(120, try a.req("seconds")), types: try a.strings("types"),
                                            taps: try a.strings("taps") ?? ["hid", "session"], path: try a.string("path")))
        },
        ToolDef(name: "watch_events", description: "Compact list of the events a tap sees for `seconds` (mouse moves folded into runs). Each entry shows type, keyCode, flags with modifier names, location, synthetic (posted by MacWright) and, for gestures, the NSEvent type/stage/pressure. To check what one MacWright action delivered, pass watch: true to that tool instead.",
                schema: S.object(["seconds": S.num("How long to watch (max 60)"), "tap": S.enum(["session", "hid", "both"], "Default session"),
                                  "types": S.strs("Only these event types")], required: ["seconds"])) { a in
            let rec = EventRecorder(fullFields: false)
            try rec.start(Recording.taps(try a.string("tap") ?? "session"))
            defer { rec.stop() }
            _ = rec.waitLive()
            var left = min(60, try a.req("seconds")) * 1000
            while left > 0 { try Control.shared.checkPaused(); usleep(100_000); left -= 100 }
            let ev = rec.results(types: try Recording.typeSet(try a.strings("types")))
            return ToolOutput(["seen": ev.count, "events": summarize(ev, limit: 300)])
        },
    ]

    // MARK: Info

    static let info: [ToolDef] = [
        ToolDef(name: "status", description: "MacWright state: permissions, paused, cursor, displays count, held inputs, server address, the human-input monitor's totals (humanInputMonitor) and whether watch_focus is running. Like every result it carries humanInput.",
                schema: S.object([:]), whilePaused: true) { _ in
            ToolOutput([
                "permissions": Permission.json, "paused": Control.shared.paused, "held": Driver.shared.held,
                "displays": Displays.all().count, "server": AppState.serverAddress, "version": AppState.version,
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "humanInputMonitor": HumanInput.shared.summary(),
                "humanQuietMsDefault": defaultHumanQuietMs,
                "focusWatch": FocusWatch.shared.state(),
            ])
        },
        ToolDef(name: "displays", description: "Every display: id, name, bounds in global points (origin top-left of the main display, y down), pixel size, scale, isMain, and neighbours (which display touches which edge, over which stretch).",
                schema: S.object([:]), whilePaused: true) { _ in
            ToolOutput(["displays": Displays.allJSON()])
        },
        ToolDef(name: "event_taps", description: "Every CGEventTap on the system (CGGetEventTapList): tapping process, location (hid/session/annotated), mode (active or listen-only), enabled, event mask and min/avg/max latency in ms. An ACTIVE tap that is enabled but never serviced holds up the session pipeline until macOS times it out, and keys typed meanwhile are lost system-wide. Filter by process name or pid.",
                schema: S.object(["process": S.str("Only taps of this process (name substring or pid)")]), whilePaused: true) { a in
            ToolOutput(["taps": EventTaps.list(filter: try a.string("process"))])
        },
        ToolDef(name: "cursor", description: "Current cursor position (global points) and the display under it.",
                schema: S.object([:]), whilePaused: true) { _ in ToolOutput() },
        ToolDef(name: "selftest", description: "Posts input and checks what a tap actually received (read after a fence event reached the tap, so slow delivery is waited for, never mistaken for loss). suite mouse (default): a short move and a left click (at x,y if given) seen by a session tap — real events. keys: cmd/opt/shift/ctrl and two-modifier chords, an arrow, click+cmd and type_text, checked at the HID tap (where HID-level apps listen) against the hardware model — swallowed there, so no app receives them. force: force_click checked for a type-29 gesture with NSEvent type 34 reaching stage 2 — swallowed too. all: every suite.",
                schema: S.object(["suite": S.enum(["mouse", "keys", "force", "all"], "Default mouse"),
                                  "x": S.num("Click x (mouse suite, optional)"), "y": S.num("Click y (mouse suite, optional)"),
                                  "click": S.bool("Also click in the mouse suite (default true)")])) { a in
            ToolOutput(try SelfTest.run(suite: try a.string("suite") ?? "mouse",
                                        at: a.has("x") ? CGPoint(x: try a.req("x"), y: try a.req("y")) : nil,
                                        click: try a.bool("click", true)))
        },
    ]

    // MARK: Mouse

    static let mouse: [ToolDef] = [
        ToolDef(name: "warp", description: "Teleport the cursor to (x, y) and post a mouseMoved there. Does not cross edges like a mouse; use move_to / push_edge for that.",
                schema: S.object(["x": S.num("Global x"), "y": S.num("Global y")], required: ["x", "y"])) { a in
            try Driver.shared.warp(CGPoint(x: try a.req("x"), y: try a.req("y")))
            return ToolOutput()
        },
        ToolDef(name: "move", description: "Physical-mouse move: post `steps` relative events, each with delta (dx, dy), `intervalMs` apart. Clamped to the displays (slides along edges); uses *MouseDragged while a button is held.",
                schema: S.object(["dx": S.num("Per-step delta x"), "dy": S.num("Per-step delta y"),
                                  "steps": S.int("Events to post (default 1)"), "intervalMs": S.num("Gap between events (default 8)"),
                                  "modifiers": S.strs("Modifiers held through the move (cmd, opt, ctrl, shift, fn)")],
                                 required: ["dx", "dy"])) { a in
            let n = try a.int("steps", 1)
            let d = CGVector(dx: try a.req("dx"), dy: try a.req("dy"))
            Driver.shared.sync()
            try withModifiers(a) { try Driver.shared.moveBy(Array(repeating: d, count: max(1, n)), intervalMs: try a.double("intervalMs", 8)) }
            return ToolOutput()
        },
        ToolDef(name: "drag", description: "Like move, but with a button held: presses `button` (default left) first unless already held via `down`, posts dragged events, then releases what it pressed. With toEdge instead of dx/dy: glide to that edge of the display under the cursor, wait dwellMs, keep nudging outward (pushSteps, default 8 when dwelling), hold holdMs, then release (release: false keeps the button down) — a file drag onto a screen edge, for edge-dwell detectors that count only motion after a pause there.",
                schema: S.object(["dx": S.num("Per-step delta x"), "dy": S.num("Per-step delta y"),
                                  "steps": S.int("Events (default 1)"), "intervalMs": S.num("Gap (default 8)"),
                                  "button": S.enum(["left", "right", "middle"], "Button (default left)"),
                                  "toEdge": S.enum(["left", "right", "top", "bottom"], "Drag to this edge instead of dx/dy"),
                                  "display": S.int("toEdge: display id (default: the one under the cursor)"),
                                  "dwellMs": S.num("toEdge: wait at the edge before nudging (default 0)"),
                                  "pushSteps": S.int("toEdge: 3-point nudges outward after the dwell (default 8 with dwellMs, else 0)"),
                                  "holdMs": S.num("toEdge: keep the button down this long at the end (default 0)"),
                                  "release": S.bool("toEdge: release the button at the end (default true)"),
                                  "modifiers": S.strs("Modifiers held through the drag")])) { a in
            if let e = try a.string("toEdge") {
                guard let edge = Edge(rawValue: e) else { throw ToolError("toEdge must be left, right, top or bottom") }
                return ToolOutput(try withModifiers(a) { try dragToEdge(a, edge: edge) })
            }
            guard a.has("dx"), a.has("dy") else { throw ToolError("give dx and dy, or toEdge") }
            let mods = try modifiers(a)
            try Driver.shared.pressModifiers(mods)
            defer { Driver.shared.releaseModifiers(mods) }
            let b = try MouseButton.parse(try a.string("button"))
            let pressed = !Driver.shared.isHeld(b)
            if pressed { try Driver.shared.down(b); usleep(30_000) }
            defer { if pressed { Driver.shared.up(b) } }
            let d = CGVector(dx: try a.req("dx"), dy: try a.req("dy"))
            try Driver.shared.moveBy(Array(repeating: d, count: max(1, try a.int("steps", 1))), intervalMs: try a.double("intervalMs", 8))
            return ToolOutput(["autoPressed": pressed])
        },
        ToolDef(name: "move_to", description: "Glide smoothly (ease-in-out) from the current position to (x, y) over durationMs using posted relative deltas, like a real mouse. Reports whether it arrived (an edge between displays can block the path).",
                schema: S.object(["x": S.num("Target x"), "y": S.num("Target y"), "durationMs": S.num("Default 300"),
                                  "modifiers": S.strs("Modifiers held through the glide")],
                                 required: ["x", "y"])) { a in
            let target = CGPoint(x: try a.req("x"), y: try a.req("y"))
            let reached = try withModifiers(a) { try Driver.shared.moveTo(target, durationMs: try a.double("durationMs", 300)) }
            return ToolOutput(["reached": reached, "target": target])
        },
        ToolDef(name: "push_edge", description: "Drive into a display edge like a user pushing the mouse off-screen: start just inside the edge at `along` (0 = top/left end, 1 = bottom/right end), glide to the edge with posted deltas, wait dwellMs, then keep pushing outward by `distance` points in `steps` events. This is how to trigger an app's screen-edge switch.",
                schema: S.object(["edge": S.enum(["left", "right", "top", "bottom"], "Edge"),
                                  "display": S.int("Display id (default main)"), "along": S.num("0..1 along the edge (default 0.5)"),
                                  "distance": S.num("Points to push past the edge (default 200)"), "steps": S.int("Push events (default 20)"),
                                  "intervalMs": S.num("Gap between push events (default 8)"), "dwellMs": S.num("Wait at the edge first (default 0)"),
                                  "modifiers": S.strs("Modifiers held through the whole push, e.g. [\"cmd\"] for an edge switch that requires ⌘, or [\"fn\"]; they come up after the last push event")],
                                 required: ["edge"])) { a in
            guard let edge = Edge(rawValue: try a.reqString("edge")) else { throw ToolError("edge must be left, right, top or bottom") }
            let pushMods = try modifiers(a)
            try Driver.shared.pressModifiers(pushMods)
            defer { Driver.shared.releaseModifiers(pushMods) }
            let d = try Displays.find(try a.int("display"))
            let plan = planPushEdge(bounds: d.bounds, edge: edge, along: try a.double("along", 0.5),
                                    distance: try a.double("distance", 200), steps: try a.int("steps", 20))
            try Driver.shared.warp(plan.start)
            try Driver.shared.moveBy(plan.approach, intervalMs: 8)
            try Driver.shared.settle(at: plan.edgePoint)
            let atEdge = Driver.shared.pos
            let dwell = try a.double("dwellMs", 0)
            if dwell > 0 { usleep(UInt32(dwell * 1000)); try Control.shared.checkPaused() }
            try Driver.shared.moveBy(plan.push, intervalMs: try a.double("intervalMs", 8))
            let end = Driver.shared.cursor
            return ToolOutput([
                "display": Int(d.id), "start": plan.start, "edgePoint": plan.edgePoint,
                "reachedEdge": abs(atEdge.x - plan.edgePoint.x) < 1 && abs(atEdge.y - plan.edgePoint.y) < 1,
                "positionAtEdge": atEdge, "pushed": plan.push.reduce(0) { $0 + abs($1.dx) + abs($1.dy) },
                "endedOnDisplay": Displays.under(end).map { Int($0.id) } as Any? ?? NSNull(),
            ])
        },
        ToolDef(name: "click", description: "Click a mouse button (count 1-3 for single/double/triple) at the current position, or warp to (x, y) first. Modifiers are held around the click.",
                schema: S.object(["button": S.enum(["left", "right", "middle"], "Default left"), "count": S.int("1, 2 or 3 (default 1)"),
                                  "x": S.num("Optional x"), "y": S.num("Optional y"), "modifiers": modsSchema])) { a in
            if a.has("x") || a.has("y") { try Driver.shared.warp(CGPoint(x: try a.req("x"), y: try a.req("y"))) }
            let mods = try modifiers(a)
            try Driver.shared.pressModifiers(mods)
            defer { Driver.shared.releaseModifiers(mods) }
            try Driver.shared.click(try MouseButton.parse(try a.string("button")), count: try a.int("count", 1))
            return ToolOutput()
        },
        ToolDef(name: "down", description: "Press and hold a mouse button at the current position (released by up, release_all, pause, quit or an error).",
                schema: S.object(["button": S.enum(["left", "right", "middle"], "Default left")])) { a in
            try Driver.shared.down(try MouseButton.parse(try a.string("button")))
            return ToolOutput(["held": Driver.shared.held])
        },
        ToolDef(name: "up", description: "Release a mouse button at the current position.",
                schema: S.object(["button": S.enum(["left", "right", "middle"], "Default left")])) { a in
            Driver.shared.up(try MouseButton.parse(try a.string("button")))
            return ToolOutput(["held": Driver.shared.held])
        },
        ToolDef(name: "force_click", description: "Force Touch click, modelled on a recorded trackpad force click: gesture began, left down, NSEventTypePressure events (CGEvent type 29, HID type force) ramping through stage 1 into stage 2 with rising pressure, back to stage 1, gesture ended, left up — about 0.6 s at the default stage2Ms. Delivered to event taps like the real thing (selftest suite force checks it). Warps to (x, y) first if given.",
                schema: S.object(["x": S.num("Optional x"), "y": S.num("Optional y"),
                                  "stage2Ms": S.num("How long to hold the deep click (stage 2), default 350")])) { a in
            if a.has("x") || a.has("y") { try Driver.shared.warp(CGPoint(x: try a.req("x"), y: try a.req("y"))) }
            try Driver.shared.forceClick(stage2Ms: try a.double("stage2Ms", 350))
            return ToolOutput()
        },
        ToolDef(name: "scroll", description: "Scroll wheel at the cursor. Deltas follow CGEvent: positive dy = wheel up (content moves down), positive dx = content moves right. unit pixel (default) or line. phases: true posts trackpad-style began/changed/ended continuous events.",
                schema: S.object(["dx": S.num("Horizontal (default 0)"), "dy": S.num("Vertical (default 0)"),
                                  "unit": S.enum(["pixel", "line"], "Default pixel"), "phases": S.bool("Trackpad phases (default false)"),
                                  "steps": S.int("Split into this many events (default 1, or 10 with phases)"),
                                  "intervalMs": S.num("Gap between events (default 16)")])) { a in
            let phased = try a.bool("phases", false)
            try Driver.shared.scroll(dx: try a.double("dx", 0), dy: try a.double("dy", 0),
                                     pixel: (try a.string("unit") ?? "pixel") != "line", phased: phased,
                                     steps: try a.int("steps", phased ? 10 : 1), intervalMs: try a.double("intervalMs", 16))
            return ToolOutput()
        },
    ]

    // MARK: Keyboard

    static let keyboard: [ToolDef] = [
        ToolDef(name: "key", description: "Press a key with optional modifiers (posted as real modifier presses); the events carry the current layout's text for it, like hardware (layoutText). Names: esc, return, tab, space, delete, forwarddelete, left/right/up/down, home, end, pageup, pagedown, f1-f20, a-z, 0-9, punctuation, volumeup/volumedown/mute; or a raw virtual keycode like 53 or 0x35.",
                schema: S.object(["key": S.str("Key name or keycode"), "modifiers": modsSchema, "holdMs": S.num("How long to hold (default 30)"),
                                  "layoutText": S.bool("Put the text the current input source gives this key (with the held modifiers) on the events, as a hardware key event carries — e.g. ⌥3 on Turkish-Q is #, the 2 key on AZERTY is é (default true). Dead keys give their spacing accent.")],
                                 required: ["key"])) { a in
            try Driver.shared.key(try KeyMap.keyCode(try a.reqString("key")), mods: try modifiers(a), holdMs: try a.double("holdMs", 30),
                                  layoutText: try a.bool("layoutText", true))
            return ToolOutput()
        },
        ToolDef(name: "type_text", description: "Type Unicode text. Every event carries the character via CGEventKeyboardSetUnicodeString (layout-independent); ASCII also uses its US keycode so keycode readers see a real key.",
                schema: S.object(["text": S.str("Text to type"), "intervalMs": S.num("Gap between characters (default 15)")], required: ["text"])) { a in
            let text = try a.reqString("text")
            try Driver.shared.type(text, intervalMs: try a.double("intervalMs", 15))
            return ToolOutput(["typed": text.count])
        },
        ToolDef(name: "hold", description: "Hold modifiers and keys down for ms, then release them (reverse order).",
                schema: S.object(["keys": S.strs("Keys to hold"), "modifiers": modsSchema, "ms": S.num("Duration (default 500)")])) { a in
            let mods = try modifiers(a)
            let codes = try (a.strings("keys") ?? []).map { try KeyMap.keyCode($0) }
            try Driver.shared.pressModifiers(mods)
            defer { Driver.shared.releaseModifiers(mods) }
            for c in codes { try Driver.shared.keyDown(c, layoutText: true) }
            defer { for c in codes.reversed() { Driver.shared.keyUp(c, layoutText: true) } }
            usleep(UInt32(max(0, try a.double("ms", 500)) * 1000))
            return ToolOutput()
        },
        ToolDef(name: "chord", description: "Hold modifiers while running steps in one call, then release them: e.g. hold [cmd], steps [{push_edge: {edge: right}}, {key: {key: tab}}, {sleepMs: 200}] is ⌘ held through a jump, Tab, then ⌘ up. Each step is one key: a tool (push_edge, move, move_to, drag, key, type_text, click, scroll, warp, down, up) with its arguments, sleepMs, or release (modifiers to let go early; [] = all held).",
                schema: S.object(["hold": S.strs("Modifiers held for the whole chord (cmd, opt, ctrl, shift, fn)"),
                                  "steps": ["type": "array", "description": "Steps, each an object with one key", "items": ["type": "object"]]],
                                 required: ["steps"])) { a in
            ToolOutput(try chord(a))
        },
        ToolDef(name: "release_all", description: "Release every mouse button, key and modifier MacWright is holding.",
                schema: S.object([:]), whilePaused: true) { _ in
            let before = Driver.shared.held
            Driver.shared.releaseAll()
            return ToolOutput(["released": before])
        },
    ]

    // MARK: Screen

    static let screen: [ToolDef] = [
        ToolDef(name: "screenshot", description: "Screenshot (Screen Recording permission) of a display (default main), a rect in global points, or a window id (from list_windows). scale is relative to native pixels (default 0.5 → 1 px per point on a 2× display). Returns the image, the saved path and the pixel→point mapping.",
                schema: S.object(["display": S.int("Display id"), "rect": rectSchema, "window": S.int("Window id"),
                                  "scale": S.num("0.05-2, default 0.5"), "format": S.enum(["png", "jpeg"], "Default png"),
                                  "cursor": S.bool("Include the cursor (default true)"), "path": S.str("Save here instead of the cache folder"),
                                  "inline": S.bool("Return the image in the result (default true)")])) { a in
            let shot = try Screen.capture(displayID: try a.int("display"), rect: try rect(a), windowID: try a.int("window"),
                                          scale: try a.double("scale", 0.5), cursor: try a.bool("cursor", true))
            let jpeg = (try a.string("format") ?? "png").lowercased().hasPrefix("j")
            let data = try Screen.encode(shot.image, jpeg: jpeg)
            let path = try a.string("path").map { ($0 as NSString).expandingTildeInPath }
                ?? Screen.shotsDir.appendingPathComponent("shot-\(Int(Date().timeIntervalSince1970 * 1000)).\(jpeg ? "jpg" : "png")").path
            try data.write(to: URL(fileURLWithPath: path))
            var json: [String: Any] = ["path": path, "bytes": data.count, "mapping": shot.mapping]
            if let id = shot.displayID { json["displayId"] = Int(id) }
            if let w = shot.windowID { json["windowId"] = Int(w) }
            return ToolOutput(json, image: try a.bool("inline", true) ? (data.base64EncodedString(), jpeg ? "image/jpeg" : "image/png") : nil)
        },
        ToolDef(name: "wait_screen_stable", description: "Wait until the screen (or rect / display) stops changing for stableMs. Returns stable and elapsedMs.",
                schema: S.object(["rect": rectSchema, "display": S.int("Display id"), "timeoutMs": S.num("Default 5000"),
                                  "stableMs": S.num("Default 500"), "threshold": S.num("Changed-pixel fraction that counts as change (default 0.001)")])) { a in
            ToolOutput(try Screen.waitStable(displayID: try a.int("display"), rect: try rect(a), timeoutMs: try a.double("timeoutMs", 5000),
                                             stableMs: try a.double("stableMs", 500), threshold: try a.double("threshold", 0.001)))
        },
        ToolDef(name: "wait_for_screen_change", description: "Wait until the screen (or rect / display) changes from how it looks now. Returns changed, elapsedMs, changedFraction.",
                schema: S.object(["rect": rectSchema, "display": S.int("Display id"), "timeoutMs": S.num("Default 5000"),
                                  "threshold": S.num("Changed-pixel fraction that counts (default 0.001)")])) { a in
            ToolOutput(try Screen.waitChange(displayID: try a.int("display"), rect: try rect(a), timeoutMs: try a.double("timeoutMs", 5000),
                                             threshold: try a.double("threshold", 0.001)))
        },
        ToolDef(name: "record", description: "Record a display to a .mov for evidence (ScreenCaptureKit, macOS 15+). Blocks for `seconds`.",
                schema: S.object(["seconds": S.num("Duration"), "display": S.int("Display id (default main)"),
                                  "path": S.str("Output .mov path")], required: ["seconds", "path"])) { a in
            ToolOutput(try Screen.record(seconds: try a.req("seconds"), displayID: try a.int("display"), path: try a.reqString("path")))
        },
    ]

    // MARK: Windows and apps

    static let windows: [ToolDef] = [
        ToolDef(name: "list_windows", description: "Windows front to back: id, owner app, pid, bundleId, title (needs Screen Recording), bounds, layer, onScreen. systemPrompt marks TCC alerts, Gatekeeper, SecurityAgent, UserNotificationCenter and similar dialogs a test cannot answer itself; they are also listed under systemPrompts — ask the human to handle those. Notification Center's always-present full-screen window counts only while it actually shows something (a banner, an alert or the open panel, read from its AX tree): see notificationCenter and promptKind (notificationBanner, notificationAlert, notificationCenterOpen).",
                schema: S.object(["app": S.str("Filter: bundle id or owner name substring"), "includeOffscreen": S.bool("Default false")])) { a in
            let all = Windows.list(app: try a.string("app"), includeOffscreen: try a.bool("includeOffscreen", false))
            let prompts = (try a.string("app") == nil ? all : Windows.list(app: nil, includeOffscreen: false))
                .filter { $0["systemPrompt"] as? Bool == true }
            return ToolOutput(["windows": all, "systemPrompts": prompts])
        },
        ToolDef(name: "launch_app", description: "Launch an app by bundle id or path, with optional arguments.",
                schema: S.object(["bundleId": S.str("Bundle id"), "path": S.str("Path to .app"), "args": S.strs("Arguments"),
                                  "activate": S.bool("Bring to front (default true)")])) { a in
            ToolOutput(try Apps.launch(bundleId: try a.string("bundleId"), path: try a.string("path"), args: try a.strings("args") ?? [],
                                       activate: try a.bool("activate", true)))
        },
        ToolDef(name: "quit_app", description: "Quit an app (force: kill) and wait for it to exit.",
                schema: S.object(["bundleId": S.str("Bundle id"), "force": S.bool("Force quit (default false)"),
                                  "timeoutMs": S.num("Wait for exit (default 5000)")], required: ["bundleId"])) { a in
            ToolOutput(try Apps.quit(try a.reqString("bundleId"), force: try a.bool("force", false), timeoutMs: try a.double("timeoutMs", 5000)))
        },
        ToolDef(name: "activate_app", description: "Bring a running app to the front.",
                schema: S.object(["bundleId": appSchema], required: ["bundleId"])) { a in
            ToolOutput(try Apps.activate(try a.reqString("bundleId")))
        },
        ToolDef(name: "running_apps", description: "Running apps: name, bundleId, pid, active, hidden, policy (regular/accessory).",
                schema: S.object(["includeBackground": S.bool("Include background-only processes (default false)")])) { a in
            ToolOutput(["apps": Apps.list(includeBackground: try a.bool("includeBackground", false))])
        },
        ToolDef(name: "open_url", description: "Open a URL (optionally with a specific app).",
                schema: S.object(["url": S.str("URL"), "bundleId": S.str("Open with this app")], required: ["url"])) { a in
            guard let url = URL(string: try a.reqString("url")) else { throw ToolError("bad url") }
            return ToolOutput(try Apps.open(url, with: try a.string("bundleId")))
        },
        ToolDef(name: "chrome_profiles", description: "Chrome profiles from its Local State: directory (what open_chrome's profile takes), display name, signed-in email, plus lastUsed and whether Chrome is running.",
                schema: S.object(["channel": S.str("stable (default), beta, dev, canary, chromium"),
                                  "userDataDir": S.str("Custom --user-data-dir instead of the channel's default")]),
                whilePaused: true) { a in
            ToolOutput(try ChromeApp.profiles(channel: try ChromeChannel.parse(try a.string("channel")), userDataDir: try a.string("userDataDir")))
        },
        ToolDef(name: "open_chrome", description: "Open Chrome, running or not: URLs as tabs in a chosen profile, a new or incognito window, an app window (appUrl), or a remote debugging port. profile matches a directory (\"Profile 1\"), display name (\"Person 1\") or signed-in email, then a unique substring; see chrome_profiles. Waits for the new window and returns its ids (opening a tab in an existing window makes none) and the arguments used. Note: remoteDebuggingPort and userDataDir only take effect when Chrome starts with them.",
                schema: S.object(["urls": S.strs("URLs to open as tabs"), "url": S.str("One URL (same as urls: [url])"),
                                  "profile": S.str("Profile directory, display name or email"),
                                  "newWindow": S.bool("Open in a new window (default false)"), "incognito": S.bool("Incognito window (default false)"),
                                  "guest": S.bool("Guest window (default false)"), "appUrl": S.str("Open this URL as an app window (--app)"),
                                  "channel": S.str("stable (default), beta, dev, canary, chromium"),
                                  "userDataDir": S.str("Custom --user-data-dir (a separate Chrome instance)"),
                                  "remoteDebuggingPort": S.int("--remote-debugging-port"), "args": S.strs("Extra Chrome flags"),
                                  "activate": S.bool("Bring Chrome to front (default true)"),
                                  "timeoutMs": S.num("Wait for the new window (default 5000)")])) { a in
            var o = Chrome.Options()
            o.urls = (try a.strings("urls") ?? []) + [try a.string("url")].compactMap { $0 }
            o.newWindow = try a.bool("newWindow", false)
            o.incognito = try a.bool("incognito", false)
            o.guest = try a.bool("guest", false)
            o.appURL = try a.string("appUrl")
            o.remoteDebuggingPort = try a.int("remoteDebuggingPort")
            o.extraArgs = try a.strings("args") ?? []
            return ToolOutput(try ChromeApp.open(channel: try ChromeChannel.parse(try a.string("channel")), profile: try a.string("profile"),
                                                 userDataDir: try a.string("userDataDir"), options: o,
                                                 activate: try a.bool("activate", true), timeoutMs: try a.double("timeoutMs", 5000)))
        },
        ToolDef(name: "open_file", description: "Open a file or folder (optionally with a specific app).",
                schema: S.object(["path": S.str("File path"), "bundleId": S.str("Open with this app")], required: ["path"])) { a in
            let path = (try a.reqString("path") as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { throw ToolError("no such file: \(path)") }
            return ToolOutput(try Apps.open(URL(fileURLWithPath: path), with: try a.string("bundleId")))
        },
    ]

    // MARK: Accessibility

    static let accessibility: [ToolDef] = [
        ToolDef(name: "ax_tree", description: "Accessibility tree of an app (or one window: index or title substring). Nodes: role, subrole, title, value, description, identifier, enabled, focused, frame (global points), path (AXChildren indexes from the app; pass it to ax_press etc.).",
                schema: S.object(["app": appSchema, "window": S.str("Window index or title substring"), "maxDepth": S.int("Default 8"),
                                  "includeMenuBar": S.bool("Default false"), "maxNodes": S.int("Default 1500")], required: ["app"])) { a in
            ToolOutput(try AX.tree(app: try a.reqString("app"), window: try a.string("window"), maxDepth: try a.int("maxDepth", 8),
                                   includeMenuBar: try a.bool("includeMenuBar", false), maxNodes: try a.int("maxNodes", 1500)))
        },
        ToolDef(name: "ax_find", description: "Find accessibility elements matching role / subrole / title / titleContains / identifier / value. Returns nodes with paths and actions.",
                schema: S.object(queryProps.merging(["app": appSchema, "maxDepth": S.int("Default 14"), "limit": S.int("Default 50")]) { a, _ in a },
                                 required: ["app"])) { a in
            let nodes = try AX.find(app: try a.reqString("app"), query: try AXQuery(a), maxDepth: try a.int("maxDepth", 14), limit: try a.int("limit", 50))
            return ToolOutput(["count": nodes.count, "nodes": nodes])
        },
        ToolDef(name: "ax_press", description: "AXPress an element given by path or query.",
                schema: S.object(["app": appSchema, "path": S.ints("Path from ax_tree/ax_find"), "query": querySchema], required: ["app"])) { a in
            let (e, path) = try AX.target(a)
            let info = AX.node(e, path: path)
            try AX.perform(e, kAXPressAction)
            return ToolOutput(["pressed": info])
        },
        ToolDef(name: "ax_set_value", description: "Set an element's AXValue (text fields, checkboxes, sliders) by path or query.",
                schema: S.object(["app": appSchema, "path": S.ints("Path"), "query": querySchema,
                                  "value": ["description": "New value (string, number or boolean)"]], required: ["app", "value"])) { a in
            let (e, path) = try AX.target(a)
            try AX.setValue(e, a.raw["value"] ?? .null)
            return ToolOutput(["element": AX.node(e, path: path)])
        },
        ToolDef(name: "ax_focus", description: "Focus an element (or raise a window) by path or query.",
                schema: S.object(["app": appSchema, "path": S.ints("Path"), "query": querySchema], required: ["app"])) { a in
            let (e, path) = try AX.target(a)
            try AX.focus(e)
            return ToolOutput(["element": AX.node(e, path: path)])
        },
        ToolDef(name: "menu_extra", description: "Open an app's menu-bar status item (AXExtrasMenuBar) and pick itemPath in its menu (e.g. an app's tray menu: [\"Check for Updates…\"]). Empty itemPath opens the menu and lists its items. Falls back to a real click when AXPress does not open it.",
                schema: S.object(["app": appSchema, "itemPath": S.strs("Menu item titles, outermost first"),
                                  "index": S.int("Which status item if the app has several (default 0)"),
                                  "clickFallback": S.bool("Click the item if AXPress does not open the menu (default true)"),
                                  "method": S.enum(["press", "click"], "press (default): AXPress. click: real clicks on the status item and the item (hovering parents), which macOS counts as a user action, so the app may bring itself forward; the result says which app is active after.")],
                                 required: ["app"])) { a in
            if (try a.string("method")) == "click" {
                return ToolOutput(try AX.menuExtraClick(app: try a.reqString("app"), index: try a.int("index", 0), itemPath: try a.strings("itemPath") ?? []))
            }
            return ToolOutput(try AX.menuExtra(app: try a.reqString("app"), index: try a.int("index", 0), itemPath: try a.strings("itemPath") ?? [],
                                        clickFallback: try a.bool("clickFallback", true)))
        },
        ToolDef(name: "menu", description: "Pick an item from an app's menu bar, e.g. [\"File\", \"New Window\"] or [\"View\", \"Sort By\", \"Name\"].",
                schema: S.object(["app": appSchema, "itemPath": S.strs("Menu, then item titles")], required: ["app", "itemPath"])) { a in
            ToolOutput(try AX.menu(app: try a.reqString("app"), itemPath: try a.strings("itemPath") ?? []))
        },
        ToolDef(name: "status_items", description: "Every app's menu-bar status items (AXExtrasMenuBar), left to right: pid, bundleId, app name, path, index (within that app), frame and center in global points, title / description / help / identifier. Tells apart two processes with the same name and look-alike icons (e.g. a dev JVM and the packaged app). app narrows to a pid, bundle id or name.",
                schema: S.object(["app": S.str("pid, bundle id or app name (optional)")])) { a in
            let items = try AX.statusItems(app: try a.string("app"))
            return ToolOutput(["items": items.map(\.json), "count": items.count])
        },
        ToolDef(name: "click_status_item", description: "Click one menu-bar status item, chosen by pid (or app: bundle id / name, which must match one process) and index (default 0). method click (default): a real mouse click at its centre — right for status items that toggle a popup instead of opening a menu. method press: AXPress. Use menu_extra to pick items in a status menu.",
                schema: S.object(["pid": S.int("Process id (from status_items)"), "app": S.str("Bundle id or name when only one process matches"),
                                  "index": S.int("Which of the app's status items (default 0)"),
                                  "method": S.enum(["click", "press"], "Default click"),
                                  "button": S.enum(["left", "right"], "Mouse button for method click (default left)")])) { a in
            let pid = try a.int("pid").map { Int32($0) }
            let app = try a.string("app")
            if pid == nil && app == nil { throw ToolError("give pid or app") }
            return ToolOutput(try AX.clickStatusItem(pid: pid, app: app, index: try a.int("index", 0),
                                                     method: try a.string("method") ?? "click", button: try MouseButton.parse(try a.string("button"))))
        },
        ToolDef(name: "watch_focus", description: "Focus/activation timeline. action start: begin recording frontmost-app changes (appActivated/appDeactivated, from NSWorkspace) and key/main-window changes inside apps (focusedWindowChanged/mainWindowChanged, from AX observers on the frontmost app, every app that becomes frontmost, and `apps`). Each event: seq, t (ms since start), atMillis, kind, pid, bundleId, app, window {windowId (as in list_windows), title, subrole, bounds} or null. action read: events after `since` (a seq; use the returned `next` as the next since) plus bounces — a window that lost focus/main and got it back within bounceMs (default 200), or an app deactivated and re-activated that fast. action stop: stop recording (events stay readable until the next start).",
                schema: S.object(["action": S.enum(["start", "read", "stop"], "Default read"),
                                  "apps": S.strs("start: also observe these apps (bundle id, name or pid) from the start"),
                                  "since": S.int("read: only events with seq > since (default 0)"),
                                  "limit": S.int("read: max events (default 500)"),
                                  "bounceMs": S.num("read: max gap for a bounce (default 200)")]), whilePaused: true) { a in
            switch try a.string("action") ?? "read" {
            case "start": return ToolOutput(try FocusWatch.shared.start(apps: try a.strings("apps") ?? [], clear: true))
            case "stop": return ToolOutput(FocusWatch.shared.stop())
            case "read": return ToolOutput(FocusWatch.shared.read(since: try a.int("since", 0), limit: try a.int("limit", 500),
                                                                  bounceMs: try a.double("bounceMs", 200)))
            default: throw ToolError("action must be start, read or stop")
            }
        },
    ]

    // MARK: Clipboard

    static let clipboard: [ToolDef] = [
        ToolDef(name: "clipboard_get", description: "Clipboard contents: string, file URLs, available types, changeCount; plus the raw data of any requested types.",
                schema: S.object(["types": S.strs("Pasteboard types to return raw (e.g. public.html)")])) { a in
            ToolOutput(Clipboard.get(types: try a.strings("types")))
        },
        ToolDef(name: "clipboard_set", description: "Set the clipboard to text or to file URLs.",
                schema: S.object(["text": S.str("Text"), "fileUrls": S.strs("File paths")])) { a in
            ToolOutput(try Clipboard.set(text: try a.string("text"), files: try a.strings("fileUrls")))
        },
        ToolDef(name: "clipboard_change_count", description: "The pasteboard change count (increments on every copy).",
                schema: S.object([:])) { _ in ToolOutput(["changeCount": NSPasteboard.general.changeCount]) },
    ]

    // MARK: Waiting

    static let waiting: [ToolDef] = [
        ToolDef(name: "wait_for_window", description: "Wait until an app has a window (optionally whose title contains titleContains). Uses window titles from Screen Recording, else AX window titles.",
                schema: S.object(["app": appSchema, "titleContains": S.str("Title substring"), "timeoutMs": S.num("Default 10000")], required: ["app"])) { a in
            let app = try a.reqString("app"), title = try a.string("titleContains")
            let start = Date(), timeout = try a.double("timeoutMs", 10000)
            while true {
                try Control.shared.checkPaused()
                let wins = Windows.list(app: app, includeOffscreen: false).filter { ($0["layer"] as? Int) == 0 }
                if let hit = wins.first(where: { w in title.map { (w["title"] as? String ?? "").localizedCaseInsensitiveContains($0) } ?? true }) {
                    return ToolOutput(["found": true, "window": hit, "elapsedMs": Int(Date().timeIntervalSince(start) * 1000)])
                }
                if let title, let (el, _) = try? AX.app(app) {
                    let axWins = (AX.attr(el, kAXWindowsAttribute) as? [AXUIElement]) ?? []
                    if let w = axWins.first(where: { (AX.str($0, kAXTitleAttribute) ?? "").localizedCaseInsensitiveContains(title) }) {
                        return ToolOutput(["found": true, "window": AX.node(w, path: []), "elapsedMs": Int(Date().timeIntervalSince(start) * 1000)])
                    }
                }
                if Date().timeIntervalSince(start) * 1000 >= timeout { return ToolOutput(["found": false, "elapsedMs": Int(timeout)]) }
                usleep(150_000)
            }
        },
        ToolDef(name: "wait_for_ax", description: "Wait until an accessibility element matching query appears in the app.",
                schema: S.object(["app": appSchema, "query": querySchema, "timeoutMs": S.num("Default 10000")], required: ["app", "query"])) { a in
            let app = try a.reqString("app")
            guard let q = try a.object("query") else { throw ToolError("missing 'query'") }
            let query = try AXQuery(q)
            let start = Date(), timeout = try a.double("timeoutMs", 10000)
            while true {
                try Control.shared.checkPaused()
                if let hit = (try? AX.find(app: app, query: query, maxDepth: 14, limit: 1))?.first {
                    return ToolOutput(["found": true, "node": hit, "elapsedMs": Int(Date().timeIntervalSince(start) * 1000)])
                }
                if Date().timeIntervalSince(start) * 1000 >= timeout { return ToolOutput(["found": false, "elapsedMs": Int(timeout)]) }
                usleep(200_000)
            }
        },
        ToolDef(name: "sleep", description: "Wait ms milliseconds (max 60000).",
                schema: S.object(["ms": S.num("Milliseconds")], required: ["ms"])) { a in
            var left = min(60_000, max(0, try a.req("ms")))
            while left > 0 {
                try Control.shared.checkPaused()
                let chunk = min(left, 100)
                usleep(UInt32(chunk * 1000))
                left -= chunk
            }
            return ToolOutput()
        },
    ]

    static let byName: [String: ToolDef] = Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

    static var mcpTools: [Tool] {
        all.map { def in
            var schema = def.schema
            // Input tools also take watch / swallow.
            if inputTools.contains(def.name), case .object(var o) = schema, case .object(var props)? = o["properties"] {
                props.merge(watchProps) { a, _ in a }
                if keyTools.contains(def.name) { props.merge(keyTargetProps) { a, _ in a } }
                o["properties"] = .object(props)
                schema = .object(o)
            }
            return Tool(name: def.name, description: def.description, inputSchema: schema)
        }
    }

    /// Runs one tool call on the serial tool queue and turns the outcome into an MCP result.
    static func call(_ name: String, _ arguments: [String: Value]?) async -> CallTool.Result {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: callSync(name, arguments)) }
        }
    }

    static func callSync(_ name: String, _ arguments: [String: Value]?) -> CallTool.Result {
        let start = Date()
        Control.shared.begin()
        var ok = true
        var note = ""
        defer {
            Control.shared.end(CallRecord(time: start, tool: name, ok: ok, ms: Int(Date().timeIntervalSince(start) * 1000), note: note))
        }
        guard let def = byName[name] else {
            ok = false; note = "unknown tool"
            return CallTool.Result(content: [.text(text: "unknown tool \(name)", annotations: nil, _meta: nil)], isError: true)
        }
        do {
            try Control.shared.checkLocked()
            if !def.whilePaused { try Control.shared.checkPaused() }
            let args = Args(arguments)
            let isInput = inputTools.contains(name)
            var recorder: EventRecorder?
            let humanStart = HumanInput.shared.total
            if keyTools.contains(name) { try Focus.requireKeyTarget(args) }
            if isInput {
                try HumanInput.shared.requireQuiet(try args.double("humanQuietMs") ?? defaultHumanQuietMs)
                Driver.shared.beginLog()
                let swallow = try args.bool("swallow", false)
                if let taps = try Recording.watchTaps(args), !taps.isEmpty || swallow {
                    let r = EventRecorder(fullFields: false)
                    try r.start(taps, swallowSynthetic: swallow)
                    if !r.waitLive() { Log.write("watch: tap not live in time") }
                    recorder = r
                }
            }
            defer { recorder?.stop() }
            var whenInfo: [String: Any]?
            if isInput, let w = try args.object("when") {
                whenInfo = try LogTrigger.wait(w)
                // The wait can be long (an app relaunch), and the active app may change meanwhile.
                if keyTools.contains(name) { try Focus.requireKeyTarget(args) }
            }
            var out = try def.run(args)
            // Locked while it ran: the result (a screenshot, an AX tree, a recording) must not leave.
            try Control.shared.checkLocked()
            if let whenInfo { out.json["when"] = whenInfo }
            if isInput {
                out.json["posted"] = Driver.shared.postedSummary()
                out.json["pointer"] = Driver.shared.pointerSummary()
            }
            if let r = recorder {
                let f = r.fence()
                let ev = r.results()
                var obs: [String: Any] = ["seen": ev.count, "events": summarize(ev), "complete": f.seen,
                                          "fence": ["seen": f.seen, "ms": f.ms]]
                if !f.seen {
                    obs["fence"] = ["seen": false, "ms": f.ms, "missing": f.missing]
                    // The fence is a zero-delta mouse move: while an app has captured the mouse (cursor hidden), its
                    // HID tap consumes it before the session tap, so a missing session tap is expected then.
                    obs["note"] = cursorHidden() && !f.missing.contains("hid")
                        ? "The cursor is hidden — most likely an app has captured the mouse — and its HID tap consumed the fence before the session tap. Expected during capture; the hid tap's events are complete."
                        : "A tap never saw MacWright's fence event, so it is not receiving MacWright's events (another app's tap consuming them, e.g. an app that has captured the mouse — try swallow: true)."
                }
                let disabled = r.disabledCounts
                if !disabled.isEmpty { obs["tapDisabled"] = disabled }
                out.json["observed"] = obs
            }
            out.json["humanInput"] = HumanInput.shared.report(advance: true, duringFrom: humanStart)
            out.json["cursor"] = Displays.cursorJSON()
            out.json["activeApp"] = Focus.activeJSON()
            out.json["ok"] = true
            let v = toValue(out.json)
            var content: [Tool.Content] = [.text(text: jsonText(v), annotations: nil, _meta: nil)]
            if let img = out.image { content.append(.image(data: img.base64, mimeType: img.mime, annotations: nil, _meta: nil)) }
            Log.write("tool \(name) ok \(Int(Date().timeIntervalSince(start) * 1000))ms")
            return CallTool.Result(content: content, structuredContent: v as Value?, isError: false)
        } catch is LockedError {
            ok = false; note = "locked"
            Driver.shared.releaseAll()
            Log.write("tool \(name) refused: locked")
            // Nothing about the Mac (cursor, active app, input) goes out once it is locked.
            let v = toValue(["ok": false, "error": LockedError().description, "locked": true])
            return CallTool.Result(content: [.text(text: jsonText(v), annotations: nil, _meta: nil)], structuredContent: v as Value?, isError: true)
        } catch {
            ok = false
            let message = (error is ToolError || error is PausedError || error is KeyMapError) ? "\(error)" : error.localizedDescription
            note = message
            // A failed call must never leave a button or key stuck down.
            Driver.shared.releaseAll()
            Log.write("tool \(name) error: \(message)")
            let v = toValue(["ok": false, "error": message, "paused": Control.shared.paused, "cursor": Displays.cursorJSON(),
                             "activeApp": Focus.activeJSON(),
                             "humanInput": HumanInput.shared.report(advance: true)])
            return CallTool.Result(content: [.text(text: jsonText(v), annotations: nil, _meta: nil)], structuredContent: v as Value?, isError: true)
        }
    }

    static let instructions = """
        Drives this Mac's mouse, keyboard, screen, accessibility and clipboard for end-to-end tests. Coordinates are CoreGraphics global points (origin top-left of the main display, y down). Relative moves post deltas like a physical mouse; use push_edge to cross a display edge.
        Every result carries humanInput: input MacWright did not post (the human's mouse, trackpad, keys, scrolls, or another app's events) — sinceLastCall, duringCall, kinds, msAgo. If it is non-zero around a step, the human may have interfered: re-check the screen before trusting the step. Input tools take humanQuietMs to refuse while the human is active.
        watch: true on an input tool returns observed (what a tap saw), read after a fence event so slow delivery is waited for; observed.complete=false means a tap is not receiving MacWright's events at all.
        watch_focus start/read/stop records frontmost-app and key/main-window changes with timestamps; read returns bounces (a window losing focus and getting it back quickly).
        status_items lists every app's menu-bar status items with pid, bundleId and frame; click_status_item clicks one for real (by pid when two apps share a name).
        If list_windows shows systemPrompts, stop and ask the human. A notification banner (promptKind notificationBanner) goes away by itself: wait a few seconds and list again before asking.
        Keys go to the active app (every result's activeApp). key, type_text, hold and chord refuse while a terminal that may host you is active (an Esc there cancels your own tool call); bring the target forward with activate_app or pass keyTarget. Modifiers can be held through push_edge / move / move_to / drag (modifiers) or a whole sequence (chord). drag toEdge with dwellMs does a file drag onto an edge. menu_extra method click uses real clicks (a user action). Any input tool takes when {file, regex} to act the moment a log line appears. pointer.moves=false means relative moves didn't move the cursor.
        """

    /// A fresh MCP server for one session.
    static func makeServer() async -> Server {
        let server = Server(name: "MacWright", version: AppState.version,
                            instructions: Self.instructions,
                            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: Tools.mcpTools) }
        await server.withMethodHandler(CallTool.self) { params in await Tools.call(params.name, params.arguments) }
        return server
    }
}
