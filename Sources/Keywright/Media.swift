// Microphone and camera capture (AVFoundation): listing devices, recording audio to .m4a (blocking,
// or start/stop in the background) and grabbing one still from a camera. The macOS grant belongs
// to Keywright, the one signed app; a call while locked is refused, a running blocking recording
// stops within 0.1 s of locking or pausing, and a background one is stopped and deleted then too.
import AVFoundation
import AppKit
import CoreImage
import Foundation
import KeywrightCore

enum MediaAccess {
    private static let lock = NSLock()
    private static var asked: Set<AVMediaType> = []

    static func what(_ media: AVMediaType) -> String { media == .audio ? "microphone" : "camera" }
    static func pane(_ media: AVMediaType) -> String {
        "x-apple.systempreferences:com.apple.preference.security?" + (media == .audio ? "Privacy_Microphone" : "Privacy_Camera")
    }

    static func status(_ media: AVMediaType) -> String {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return "granted"
        case .notDetermined: return "notAsked"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    /// Throws unless Keywright may use `media`. When macOS hasn't asked yet, this shows its prompt
    /// and returns "waiting for permission" at once instead of blocking: only the person at the Mac
    /// can answer it, and Keywright never answers it for them.
    static func require(_ media: AVMediaType) throws {
        let w = what(media), title = w == "camera" ? "Camera" : "Microphone"
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return
        case .notDetermined:
            let first = lock.withLock { asked.insert(media).inserted }
            if first {
                Log.write("asking macOS for \(w) permission")
                AVCaptureDevice.requestAccess(for: media) { ok in
                    lock.withLock { _ = asked.remove(media) }
                    Log.write("\(w) permission \(ok ? "granted" : "refused") by the user")
                }
                // Someone at the Mac may answer quickly; give them a moment before reporting back.
                let until = Date().addingTimeInterval(3)
                while Date() < until, AVCaptureDevice.authorizationStatus(for: media) == .notDetermined {
                    try Control.shared.checkPaused()
                    usleep(100_000)
                }
                if AVCaptureDevice.authorizationStatus(for: media) != .notDetermined { return try require(media) }
            }
            throw ToolError("waiting for permission: macOS is asking whether Keywright may use the \(w). Only the person at this Mac can answer that prompt (an agent must not, and Keywright refuses input while it shows). Ask them to answer it, then call again.")
        case .denied:
            throw ToolError("\(w) permission is off for Keywright. The person at this Mac can turn it on in System Settings › Privacy & Security › \(title) (open \"\(pane(media))\"), then call again.")
        case .restricted:
            throw ToolError("\(w) access is restricted on this Mac (a device-management profile or Screen Time), so Keywright can't use it. Only an administrator can change that.")
        @unknown default:
            throw ToolError("unknown \(w) permission state")
        }
    }
}

enum MediaDevices {
    static func all() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.microphone, .builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]
        types = Array(Set(types))
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: nil, position: .unspecified).devices
    }

    static func fourCC(_ v: Int32) -> String {
        let u = UInt32(bitPattern: v)
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((u >> $0) & 0xFF))) }
        return chars.allSatisfy { $0.isASCII && !$0.isWhitespace || $0 == " " } ? String(chars) : String(u)
    }

    static func info(_ d: AVCaptureDevice) -> MediaDevice {
        MediaDevice(id: d.uniqueID, name: d.localizedName, modelID: d.modelID, manufacturer: d.manufacturer,
                    audio: d.hasMediaType(.audio), video: d.hasMediaType(.video), muxed: d.hasMediaType(.muxed),
                    builtIn: fourCC(d.transportType) == "bltn", deskView: d.deviceType == .deskViewCamera)
    }

    static func json(_ d: AVCaptureDevice) -> [String: Any] {
        let i = info(d)
        var media: [String] = []
        if i.audio { media.append("audio") }
        if i.video { media.append("video") }
        if i.muxed { media.append("muxed") }
        let transport: String = {
            switch fourCC(d.transportType) {
            case "bltn": return "builtIn"
            case "usb ": return "usb"
            case "blue", "blea": return "bluetooth"
            case "virt": return "virtual"
            case "ccwd", "cont": return "continuity"
            case "wifi": return "wireless"
            case "othr": return "other"
            case "thun": return "thunderbolt"
            case let t: return t.trimmingCharacters(in: .whitespaces)
            }
        }()
        return ["id": i.id, "name": i.name, "modelID": i.modelID, "manufacturer": i.manufacturer, "mediaTypes": media,
                "deviceType": d.deviceType.rawValue.replacingOccurrences(of: "AVCaptureDeviceType", with: ""),
                "transport": transport, "builtIn": i.builtIn, "deskView": i.deskView, "iPhone": i.isIPhone,
                "connected": d.isConnected, "suspended": d.isSuspended, "inUseByAnotherApp": d.isInUseByAnotherApplication]
    }

    static func list() -> [String: Any] {
        let ds = all()
        let audio = ds.filter { info($0).supports(.audio) }
        let video = ds.filter { info($0).supports(.video) }
        return ["audioInputs": audio.map(json), "videoDevices": video.map(json),
                "defaultAudioInput": AVCaptureDevice.default(for: .audio)?.uniqueID as Any? ?? NSNull(),
                "defaultCamera": AVCaptureDevice.default(for: .video)?.uniqueID as Any? ?? NSNull(),
                "permissions": ["microphone": MediaAccess.status(.audio), "camera": MediaAccess.status(.video)]]
    }

    static func find(_ spec: String?, kind: MediaKind) throws -> AVCaptureDevice {
        let ds = all()
        let media: AVMediaType = kind == .audio ? .audio : .video
        let pick = try MediaMatch.resolve(spec, in: ds.map(info), kind: kind, defaultID: AVCaptureDevice.default(for: media)?.uniqueID)
        guard let d = ds.first(where: { $0.uniqueID == pick.id }) else { throw ToolError("device \(pick.name) went away") }
        return d
    }
}

// MARK: Audio

final class AudioRecording: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let id: String
    let url: URL
    let device: MediaDevice
    let maxSeconds: Double
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioFileOutput()
    private let startedSem = DispatchSemaphore(value: 0)
    private let finishedSem = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _startedAt: Date?
    private var _endedAt: Date?
    private var _finished = false
    private var _error: Error?
    var hitLimit = false

    var startedAt: Date? { lock.withLock { _startedAt } }
    var finished: Bool { lock.withLock { _finished } }
    var seconds: Double {
        lock.withLock { _startedAt.map { (_endedAt ?? Date()).timeIntervalSince($0) } ?? 0 }
    }

    init(id: String, device: AVCaptureDevice, url: URL, maxSeconds: Double) throws {
        self.id = id
        self.url = url
        self.device = MediaDevices.info(device)
        self.maxSeconds = maxSeconds
        super.init()
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            throw ToolError("could not open \(device.localizedName): \(error.localizedDescription)")
        }
        guard session.canAddInput(input) else { throw ToolError("could not use \(device.localizedName) as an audio input") }
        session.addInput(input)
        guard session.canAddOutput(output) else { throw ToolError("cannot record audio from \(device.localizedName)") }
        session.addOutput(output)
    }

    /// Starts the session and the file, and waits until the file has really started (so a caller
    /// can play the sound right after this returns).
    func begin() throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        session.startRunning()
        output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
        let until = Date().addingTimeInterval(5)
        while startedSem.wait(timeout: .now() + 0.1) == .timedOut {
            if finished { break }
            if Control.shared.locked || Date() > until {
                discard()
                if Control.shared.locked { throw LockedError() }
                throw ToolError("the recording didn't start within 5 s on \(device.name)")
            }
        }
        // A file output that can't write (a full disk) starts and then stops at once: wait a
        // moment, so `start` never reports a recording that has already died.
        let settle = Date().addingTimeInterval(0.25)
        while !finished && Date() < settle { usleep(20_000) }
        if finished {
            let e = lock.withLock { _error }
            session.stopRunning()
            try? FileManager.default.removeItem(at: url)
            throw ToolError("the recording stopped as soon as it started: \(e?.localizedDescription ?? "no reason given")")
        }
    }

    /// Stops and waits for the file to be finalized. Returns the recording error, if any.
    @discardableResult
    func end() -> Error? {
        if !finished { output.stopRecording() }
        _ = finishedSem.wait(timeout: .now() + 10)
        finishedSem.signal()  // later waiters return at once
        session.stopRunning()
        return lock.withLock { _error }
    }

    /// Stops and deletes the file (locked, paused or failed).
    func discard() {
        end()
        try? FileManager.default.removeItem(at: url)
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        lock.withLock { _startedAt = Date() }
        startedSem.signal()
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        lock.withLock {
            if _startedAt == nil { _startedAt = Date() }
            _endedAt = Date()
            _finished = true
            // A recording stopped on purpose still reports an "error" carrying this flag.
            if let e = error as NSError?, (e.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) != true { _error = e }
        }
        startedSem.signal()
        finishedSem.signal()
    }

    var summary: [String: Any] {
        ["id": id, "path": url.path, "device": device.name, "deviceId": device.id, "seconds": round1(seconds),
         "maxSeconds": maxSeconds, "finished": finished, "hitLimit": hitLimit]
    }
}

private func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
private func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

enum AudioRecorder {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var active: [String: AudioRecording] = [:]
    nonisolated(unsafe) private static var watchdog: DispatchSourceTimer?
    nonisolated(unsafe) private static var counter = 0

    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Keywright/media")
    }

    static func outputURL(_ path: String?, prefix: String, ext: [String]) throws -> URL {
        guard let path else {
            return dir.appendingPathComponent("\(prefix)-\(Int(Date().timeIntervalSince1970 * 1000)).\(ext[0])")
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard ext.contains(url.pathExtension.lowercased()) else {
            throw ToolError("path must end in ." + ext.joined(separator: " or ."))
        }
        return url
    }

    static func run(_ req: AudioRecordRequest, device spec: String?, path: String?, loudDb: Double) throws -> [String: Any] {
        switch req {
        case .list:
            return ["recordings": lock.withLock { active.values.map(\.summary) }]
        case .stop(let id):
            let rec: AudioRecording = try lock.withLock {
                if let id {
                    guard let r = active[id] else { throw ToolError("no recording \(id) (running: \(active.keys.sorted().joined(separator: ", ")))") }
                    return r
                }
                guard active.count == 1, let r = active.values.first else {
                    throw ToolError(active.isEmpty ? "no recording is running" : "several recordings are running, give id: \(active.keys.sorted().joined(separator: ", "))")
                }
                return r
            }
            let err = rec.end()
            remove(rec.id)
            if let err { throw ToolError("recording failed: \(err.localizedDescription)") }
            return finishedResult(rec, loudDb: loudDb)
        case .blocking(let seconds):
            let rec = try open(spec: spec, path: path, maxSeconds: seconds)
            try rec.begin()
            // In 0.1 s slices, so Lock or Pause stops it at once; a recording cut short is deleted.
            let end = Date().addingTimeInterval(seconds)
            while Date() < end && !rec.finished {
                do { try Control.shared.checkPaused() } catch { rec.discard(); throw error }
                usleep(100_000)
            }
            if let err = rec.end() { throw ToolError("recording failed: \(err.localizedDescription)") }
            return finishedResult(rec, loudDb: loudDb)
        case .start(let maxSeconds):
            let rec = try open(spec: spec, path: path, maxSeconds: maxSeconds)
            try rec.begin()
            lock.withLock { active[rec.id] = rec }
            startWatchdog()
            Log.write("audio recording \(rec.id) started on \(rec.device.name) → \(rec.url.path)")
            var out = rec.summary
            out["recording"] = true
            out["note"] = "Recording. Do what you need (play the sound, tap the phone), then call record_audio {action: \"stop\", id: \"\(rec.id)\"}. It stops by itself after \(Int(maxSeconds)) s; locking or pausing Keywright stops and deletes it."
            return out
        }
    }

    private static func open(spec: String?, path: String?, maxSeconds: Double) throws -> AudioRecording {
        try MediaAccess.require(.audio)
        let device = try MediaDevices.find(spec, kind: .audio)
        let url = try outputURL(path, prefix: "audio", ext: ["m4a"])
        let id: String = lock.withLock {
            if let clash = active.values.first(where: { $0.url == url }) { return "clash:" + clash.id }
            counter += 1
            return "a\(counter)"
        }
        if id.hasPrefix("clash:") { throw ToolError("recording \(id.dropFirst(6)) is already writing \(url.path)") }
        return try AudioRecording(id: id, device: device, url: url, maxSeconds: maxSeconds)
    }

    private static func remove(_ id: String) {
        lock.withLock {
            active[id] = nil
            if active.isEmpty { watchdog?.cancel(); watchdog = nil }
        }
    }

    /// Every 0.1 s: Lock or Pause stops and deletes every background recording; one past its maxSeconds
    /// is stopped (and kept, for stop to collect).
    private static func startWatchdog() {
        lock.withLock {
            guard watchdog == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "keywright.media.watchdog"))
            t.schedule(deadline: .now() + 0.1, repeating: 0.1)
            t.setEventHandler {
                if Control.shared.locked { discardAll(reason: "locked"); return }
                if Control.shared.paused { discardAll(reason: "paused"); return }
                for r in lock.withLock({ Array(active.values) }) where !r.finished && r.seconds >= r.maxSeconds {
                    r.hitLimit = true
                    r.end()
                    Log.write("audio recording \(r.id) reached its \(Int(r.maxSeconds)) s limit")
                }
            }
            watchdog = t
            t.resume()
        }
    }

    /// Stops and deletes every background recording (Lock, Quit).
    static func discardAll(reason: String) {
        let recs: [AudioRecording] = lock.withLock {
            let r = Array(active.values)
            active = [:]
            watchdog?.cancel(); watchdog = nil
            return r
        }
        for r in recs {
            r.discard()
            Log.write("audio recording \(r.id) stopped and deleted (\(reason))")
        }
    }

    private static func finishedResult(_ rec: AudioRecording, loudDb: Double) -> [String: Any] {
        var out = rec.summary
        out["recording"] = false
        out["bytes"] = (try? FileManager.default.attributesOfItem(atPath: rec.url.path)[.size] as? Int) ?? 0
        if let a = try? analyze(rec.url, thresholdDb: loudDb) {
            out.merge(a) { _, n in n }
        } else {
            out["analysis"] = "could not read the file back"
        }
        return out
    }

    /// Duration, overall peak/RMS, and the stretches at or above thresholdDb (100 ms windows).
    static func analyze(_ url: URL, thresholdDb: Double) throws -> [String: Any] {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let rate = fmt.sampleRate
        let window = AVAudioFrameCount(max(1, rate / 10))
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: window) else { throw ToolError("buffer") }
        var levels: [Double] = []
        var peak = 0.0, sumSq = 0.0, total = 0
        while file.framePosition < file.length {
            try file.read(into: buf, frameCount: window)
            let n = Int(buf.frameLength)
            guard n > 0, let ch = buf.floatChannelData else { break }
            var wPeak = 0.0, wSq = 0.0
            for c in 0..<Int(fmt.channelCount) {
                for i in 0..<n {
                    let v = Double(ch[c][i])
                    wPeak = max(wPeak, abs(v))
                    wSq += v * v
                }
            }
            let count = n * Int(fmt.channelCount)
            levels.append(AudioLevels.db(sqrt(wSq / Double(count))))
            peak = max(peak, wPeak)
            sumSq += wSq
            total += count
        }
        let loud = AudioLevels.loudStretches(levelsDb: levels, windowSeconds: 0.1, thresholdDb: thresholdDb)
        return ["durationSeconds": round2(Double(file.length) / rate), "sampleRate": Int(rate), "channels": Int(fmt.channelCount),
                "peakDb": round1(AudioLevels.db(peak)), "rmsDb": round1(AudioLevels.db(total > 0 ? sqrt(sumSq / Double(total)) : 0)),
                "digitalSilence": peak == 0, "loudThresholdDb": thresholdDb,
                "loud": loud.prefix(100).map { ["start": round1($0.start), "end": round1($0.end), "peakDb": round1($0.peakDb)] },
                "loudCount": loud.count]
    }
}

// MARK: Camera

private final class FrameGrab: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let warmup: Double
    let sem = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var first: Date?
    private var frames = 0
    private var image: CGImage?
    private let ctx = CIContext()

    init(warmup: Double) { self.warmup = warmup }

    var result: (CGImage?, Int) { lock.withLock { (image, frames) } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        let ready: Bool = lock.withLock {
            guard image == nil else { return false }
            frames += 1
            if first == nil { first = now }
            // The first frames come before exposure and white balance settle (dark or green).
            return now.timeIntervalSince(first!) >= warmup
        }
        guard ready, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return }
        lock.withLock { image = cg }
        sem.signal()
    }
}

enum Camera {
    static func captureFrame(device spec: String?, warmupMs: Double, timeoutMs: Double) throws -> (CGImage, MediaDevice, Int) {
        try MediaAccess.require(.video)
        let device = try MediaDevices.find(spec, kind: .video)
        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            throw ToolError("could not open \(device.localizedName): \(error.localizedDescription)")
        }
        guard session.canAddInput(input) else { throw ToolError("could not use \(device.localizedName) as a camera") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        let grab = FrameGrab(warmup: max(0, warmupMs) / 1000)
        output.setSampleBufferDelegate(grab, queue: DispatchQueue(label: "keywright.camera"))
        guard session.canAddOutput(output) else { throw ToolError("cannot read frames from \(device.localizedName)") }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        defer {
            output.setSampleBufferDelegate(nil, queue: nil)
            session.stopRunning()
        }
        let until = Date().addingTimeInterval(clampedSleepMs(timeoutMs) / 1000)
        while grab.sem.wait(timeout: .now() + 0.1) == .timedOut {
            try Control.shared.checkPaused()
            if Date() > until {
                let frames = grab.result.1
                throw ToolError(frames == 0
                    ? "no frames from \(device.localizedName) within \(Int(timeoutMs)) ms (is it connected, awake and not in use elsewhere? A Continuity Camera iPhone must be locked, on a stand, near the Mac)"
                    : "only \(frames) frames from \(device.localizedName) within \(Int(timeoutMs)) ms; raise timeoutMs or lower warmupMs")
            }
        }
        let (img, frames) = grab.result
        guard let img else { throw ToolError("no frame") }
        return (img, MediaDevices.info(device), frames)
    }
}
