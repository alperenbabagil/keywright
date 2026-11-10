// Pure logic behind the media tools: picking a capture device from what a caller wrote, the
// record_audio argument shapes, and finding the loud stretches in a level track. No AVFoundation
// here, so it is unit-testable without camera or microphone permission.
import Foundation

/// One capture device as the tools see it (filled from AVCaptureDevice by the app).
public struct MediaDevice: Equatable {
    public var id: String
    public var name: String
    public var modelID: String
    public var manufacturer: String
    public var audio: Bool
    public var video: Bool
    public var muxed: Bool
    /// The Mac's own microphone or camera.
    public var builtIn: Bool
    /// A Desk View camera (the top-down crop macOS adds for the Mac's or an iPhone's camera).
    public var deskView: Bool

    public init(id: String, name: String, modelID: String, manufacturer: String = "",
                audio: Bool = false, video: Bool = false, muxed: Bool = false, builtIn: Bool = false, deskView: Bool = false) {
        self.id = id; self.name = name; self.modelID = modelID; self.manufacturer = manufacturer
        self.audio = audio; self.video = video; self.muxed = muxed; self.builtIn = builtIn
        self.deskView = deskView
    }

    /// A Continuity Camera iPhone (its camera "<name> Camera" or microphone "<name> Microphone").
    public var isIPhone: Bool { modelID.lowercased().hasPrefix("iphone") }

    public func supports(_ kind: MediaKind) -> Bool {
        switch kind {
        case .audio: return audio || muxed
        case .video: return video || muxed
        }
    }
}

public enum MediaKind: String {
    case audio, video
    var noun: String { self == .audio ? "audio input" : "camera" }
}

public enum MediaMatch {
    /// Lowercased, with typographic apostrophes made plain ("alperen’s iPhone" = "alperen's iphone").
    public static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Picks the device `spec` names, among the devices that can capture `kind`.
    /// - nil, "" or "default": the system default (`defaultID`), else the built-in one, else the first.
    /// - "mac-mic" / "mac-camera" (also "mac", "built-in"): the Mac's own device.
    /// - "iphone" or "iphone:<name>": a Continuity Camera iPhone; with a name, the one whose device
    ///   name is that name, "<name> Camera" / "<name> Microphone", or starts with it.
    /// Wherever several devices fit, a Desk View camera loses to the main one; name it
    /// ("… Desk View Camera") to get it.
    /// - otherwise: the exact unique id, then the exact name, then the exact modelID, then a unique
    ///   name substring (all case-insensitive).
    public static func resolve(_ spec: String?, in devices: [MediaDevice], kind: MediaKind, defaultID: String? = nil) throws -> MediaDevice {
        // Main devices first, so "the first one" is never a Desk View crop.
        let all = devices.filter { $0.supports(kind) }
        let candidates = all.filter { !$0.deskView } + all.filter(\.deskView)
        guard !candidates.isEmpty else { throw ToolError("no \(kind.noun) found") }
        let raw = (spec ?? "").trimmingCharacters(in: .whitespaces)
        let s = normalize(raw)
        if s.isEmpty || s == "default" {
            if let d = defaultID, let hit = candidates.first(where: { $0.id == d }) { return hit }
            return candidates.first(where: \.builtIn) ?? candidates[0]
        }
        if ["mac-mic", "mac-camera", "mac", "built-in", "builtin"].contains(s) {
            if s == "mac-mic" && kind != .audio { throw ToolError("mac-mic is a microphone; for a camera use mac-camera") }
            if s == "mac-camera" && kind != .video { throw ToolError("mac-camera is a camera; for audio use mac-mic") }
            guard let hit = candidates.first(where: \.builtIn) else { throw ToolError("this Mac has no built-in \(kind.noun)\(available(candidates))") }
            return hit
        }
        if s == "iphone" || s.hasPrefix("iphone:") {
            let phones = candidates.filter(\.isIPhone)
            let want = s == "iphone" ? "" : String(s.dropFirst("iphone:".count)).trimmingCharacters(in: .whitespaces)
            let exact = phones.filter { d in
                let n = normalize(d.name)
                return n == want || n == "\(want) camera" || n == "\(want) microphone"
            }
            if !want.isEmpty, exact.count == 1 { return exact[0] }
            let hits = preferMain(want.isEmpty ? phones : phones.filter { normalize($0.name).hasPrefix(want) })
            if hits.count == 1 { return hits[0] }
            if hits.isEmpty {
                throw ToolError("no Continuity Camera iPhone \(kind.noun)\(want.isEmpty ? "" : " named \"\(raw.dropFirst(7))\"") (the iPhone must be near the Mac, on the same Apple Account, with Continuity Camera on)\(available(candidates))")
            }
            throw ToolError("several iPhones match \"\(raw)\", name one: " + hits.map { "\"\($0.name)\"" }.joined(separator: ", "))
        }
        if let hit = candidates.first(where: { $0.id == raw }) { return hit }
        let byName = candidates.filter { normalize($0.name) == s }
        if byName.count == 1 { return byName[0] }
        let byModel = candidates.filter { normalize($0.modelID) == s }
        if byModel.count == 1 { return byModel[0] }
        let sub = preferMain(candidates.filter { normalize($0.name).contains(s) })
        if sub.count == 1 { return sub[0] }
        let many = byName.count > 1 ? byName : byModel.count > 1 ? byModel : sub
        if many.count > 1 {
            throw ToolError("\"\(raw)\" matches several devices, use an id: " + many.map { "\"\($0.name)\" (\($0.id))" }.joined(separator: ", "))
        }
        throw ToolError("no \(kind.noun) matches \"\(raw)\"\(available(candidates))")
    }

    /// The non-Desk-View devices when there are any, else all of them.
    private static func preferMain(_ ds: [MediaDevice]) -> [MediaDevice] {
        let main = ds.filter { !$0.deskView }
        return main.isEmpty ? ds : main
    }

    private static func available(_ ds: [MediaDevice]) -> String {
        "; available: " + ds.map { "\"\($0.name)\"" }.joined(separator: ", ")
    }
}

/// What a record_audio call asks for.
public enum AudioRecordRequest: Equatable {
    /// Record for this long, then return (the call blocks).
    case blocking(seconds: Double)
    /// Start in the background (stops by itself after maxSeconds).
    case start(maxSeconds: Double)
    /// Stop a background recording (the only one when id is nil).
    case stop(id: String?)
    /// List the background recordings.
    case list

    public static let maxBlockingSeconds = 600.0
    public static let maxBackgroundSeconds = 3600.0

    public static func parse(action: String?, seconds: Double?, maxSeconds: Double?, id: String?) throws -> AudioRecordRequest {
        switch action.map(MediaMatch.normalize) {
        case nil, "record"?:
            guard let seconds else {
                throw ToolError(action == nil ? "give seconds (record and wait), or action start / stop" : "action record needs seconds")
            }
            guard seconds > 0 else { throw ToolError("'seconds' must be more than 0") }
            return .blocking(seconds: min(seconds, maxBlockingSeconds))
        case "start"?:
            if seconds != nil { throw ToolError("action start takes maxSeconds, not seconds (it runs until stop)") }
            let m = maxSeconds ?? 600
            guard m > 0 else { throw ToolError("'maxSeconds' must be more than 0") }
            return .start(maxSeconds: min(m, maxBackgroundSeconds))
        case "stop"?: return .stop(id: id)
        case "list"?: return .list
        default: throw ToolError("action must be record, start, stop or list")
        }
    }
}

/// A stretch of a recording louder than a threshold.
public struct LoudStretch: Equatable {
    public var start: Double
    public var end: Double
    public var peakDb: Double
    public init(start: Double, end: Double, peakDb: Double) { self.start = start; self.end = end; self.peakDb = peakDb }
}

public enum AudioLevels {
    /// dBFS of a linear amplitude (0 → -inf is reported as -160).
    public static func db(_ amplitude: Double) -> Double {
        amplitude > 0 ? max(-160, 20 * log10(amplitude)) : -160
    }

    /// Joins consecutive windows whose level (dBFS) is at or above `thresholdDb` into stretches.
    /// Quiet gaps shorter than `bridgeSeconds` don't split a stretch (speech has short pauses).
    public static func loudStretches(levelsDb: [Double], windowSeconds: Double, thresholdDb: Double,
                                     bridgeSeconds: Double = 0.3) -> [LoudStretch] {
        var out: [LoudStretch] = []
        for (i, level) in levelsDb.enumerated() where level >= thresholdDb {
            let t0 = Double(i) * windowSeconds, t1 = t0 + windowSeconds
            if var last = out.last, t0 - last.end <= bridgeSeconds + 1e-9 {
                last.end = t1
                last.peakDb = max(last.peakDb, level)
                out[out.count - 1] = last
            } else {
                out.append(LoudStretch(start: t0, end: t1, peakDb: level))
            }
        }
        return out
    }
}
