// Screenshots, screen-change waits and recordings via ScreenCaptureKit (needs Screen Recording).
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import KeywrightCore
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Runs an async operation from a synchronous tool handler (tool handlers run on a background queue).
func blocking<T>(_ f: @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    Task.detached {
        do { result = .success(try await f()) } catch { result = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try result.get()
}

struct Shot {
    let image: CGImage
    /// Global point of the image's top-left pixel.
    let origin: CGPoint
    /// Points per image pixel: point = origin + pixel × pointsPerPixel.
    let pointsPerPixel: Double
    let displayID: CGDirectDisplayID?
    let windowID: CGWindowID?

    var mapping: [String: Any] {
        [
            "origin": origin, "pointsPerPixel": pointsPerPixel,
            "pixelWidth": image.width, "pixelHeight": image.height,
            "coversPoints": CGRect(x: origin.x, y: origin.y, width: Double(image.width) * pointsPerPixel,
                                   height: Double(image.height) * pointsPerPixel),
            "formula": "pointX = origin.x + pixelX * pointsPerPixel; pointY = origin.y + pixelY * pointsPerPixel",
        ]
    }
}

enum Screen {
    static var shotsDir: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Keywright/screenshots")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func permissionCheck() throws {
        if !CGPreflightScreenCaptureAccess() {
            throw ToolError("Keywright has no Screen Recording permission (menu bar → Screen Recording to request it)")
        }
    }

    /// Captures a display (default: main, or the one containing [rect]), a rect in global points,
    /// or a window. [scale] is relative to native pixels (0.5 on a 2× display = 1 pixel per point).
    static func capture(displayID: Int?, rect: CGRect?, windowID: Int?, scale: Double, cursor: Bool) throws -> Shot {
        try permissionCheck()
        let scale = min(2, max(0.05, scale))
        return try blocking {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: windowID == nil)
            let config = SCStreamConfiguration()
            config.showsCursor = cursor
            config.capturesAudio = false
            if let windowID {
                guard let w = content.windows.first(where: { $0.windowID == CGWindowID(windowID) }) else {
                    throw ToolError("no window with id \(windowID)")
                }
                let d = try Displays.under(CGPoint(x: w.frame.midX, y: w.frame.midY)) ?? Displays.find(nil)
                var src = CGRect(origin: .zero, size: w.frame.size)
                if let rect { src = rect.offsetBy(dx: -w.frame.minX, dy: -w.frame.minY).intersection(src) }
                guard !src.isEmpty else { throw ToolError("rect is outside the window") }
                config.sourceRect = src
                config.width = max(1, Int(src.width * d.scale * scale))
                config.height = max(1, Int(src.height * d.scale * scale))
                let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: config)
                return Shot(image: img, origin: CGPoint(x: w.frame.minX + src.minX, y: w.frame.minY + src.minY),
                            pointsPerPixel: src.width / Double(img.width), displayID: d.id, windowID: w.windowID)
            }
            let d: DisplayDesc
            if displayID == nil, let rect, let under = Displays.under(rect.origin) { d = under } else { d = try Displays.find(displayID) }
            guard let scd = content.displays.first(where: { $0.displayID == d.id }) else {
                throw ToolError("ScreenCaptureKit does not list display \(d.id)")
            }
            var global = d.bounds
            if let rect { global = rect.intersection(d.bounds) }
            guard !global.isEmpty else { throw ToolError("rect does not overlap display \(d.id) \(d.bounds)") }
            config.sourceRect = global.offsetBy(dx: -d.bounds.minX, dy: -d.bounds.minY)
            config.width = max(1, Int(global.width * d.scale * scale))
            config.height = max(1, Int(global.height * d.scale * scale))
            let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: scd, excludingWindows: []), configuration: config)
            return Shot(image: img, origin: global.origin, pointsPerPixel: global.width / Double(img.width),
                        displayID: d.id, windowID: nil)
        }
    }

    static func encode(_ img: CGImage, jpeg: Bool) throws -> Data {
        let data = NSMutableData()
        let type = (jpeg ? UTType.jpeg : UTType.png).identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else { throw ToolError("image encoder unavailable") }
        CGImageDestinationAddImage(dest, img, jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary : nil)
        guard CGImageDestinationFinalize(dest) else { throw ToolError("image encoding failed") }
        return data as Data
    }

    // MARK: Change detection

    /// RGBA bytes of a small capture, for comparing frames.
    private static func sample(displayID: Int?, rect: CGRect?) throws -> (bytes: [UInt8], w: Int, h: Int) {
        let shot = try capture(displayID: displayID, rect: rect, windowID: nil, scale: 0.15, cursor: false)
        let w = shot.image.width, h = shot.image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(shot.image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (buf, w, h)
    }

    /// Fraction of pixels that differ noticeably between two samples (1 if the sizes differ).
    private static func diff(_ a: (bytes: [UInt8], w: Int, h: Int), _ b: (bytes: [UInt8], w: Int, h: Int)) -> Double {
        guard a.w == b.w, a.h == b.h, a.w * a.h > 0 else { return 1 }
        var changed = 0
        for i in stride(from: 0, to: a.bytes.count, by: 4) {
            let d = max(abs(Int(a.bytes[i]) - Int(b.bytes[i])), abs(Int(a.bytes[i + 1]) - Int(b.bytes[i + 1])),
                        abs(Int(a.bytes[i + 2]) - Int(b.bytes[i + 2])))
            if d > 12 { changed += 1 }
        }
        return Double(changed) / Double(a.w * a.h)
    }

    static func waitStable(displayID: Int?, rect: CGRect?, timeoutMs: Double, stableMs: Double, threshold: Double) throws -> [String: Any] {
        let start = Date()
        var last = try sample(displayID: displayID, rect: rect)
        var stableSince = Date()
        while true {
            try Control.shared.checkPaused()
            usleep(100_000)
            let cur = try sample(displayID: displayID, rect: rect)
            if diff(last, cur) > threshold { stableSince = Date() }
            last = cur
            let elapsed = Date().timeIntervalSince(start) * 1000
            if Date().timeIntervalSince(stableSince) * 1000 >= stableMs {
                return ["stable": true, "elapsedMs": Int(elapsed)]
            }
            if elapsed >= timeoutMs { return ["stable": false, "elapsedMs": Int(elapsed)] }
        }
    }

    static func waitChange(displayID: Int?, rect: CGRect?, timeoutMs: Double, threshold: Double) throws -> [String: Any] {
        let start = Date()
        let base = try sample(displayID: displayID, rect: rect)
        while true {
            try Control.shared.checkPaused()
            usleep(80_000)
            let d = diff(base, try sample(displayID: displayID, rect: rect))
            let elapsed = Date().timeIntervalSince(start) * 1000
            if d > threshold { return ["changed": true, "elapsedMs": Int(elapsed), "changedFraction": d] }
            if elapsed >= timeoutMs { return ["changed": false, "elapsedMs": Int(elapsed), "changedFraction": d] }
        }
    }

    // MARK: Recording

    static func record(seconds: Double, displayID: Int?, path: String) throws -> [String: Any] {
        try permissionCheck()
        guard #available(macOS 15.0, *) else { throw ToolError("record needs macOS 15 or later") }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try? FileManager.default.removeItem(at: url)
        let d = try Displays.find(displayID)
        try blocking {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scd = content.displays.first(where: { $0.displayID == d.id }) else { throw ToolError("display \(d.id) not capturable") }
            let config = SCStreamConfiguration()
            config.width = d.pixelWidth
            config.height = d.pixelHeight
            config.showsCursor = true
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            let stream = SCStream(filter: SCContentFilter(display: scd, excludingWindows: []), configuration: config, delegate: nil)
            let rc = SCRecordingOutputConfiguration()
            rc.outputURL = url
            rc.outputFileType = .mov
            let done = RecordingDone()
            let output = SCRecordingOutput(configuration: rc, delegate: done)
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
            // Sleep in short steps so Pause or Lock stops the recording within 0.1 s.
            let end = Date().addingTimeInterval(max(0.5, min(600, seconds)))
            var stopped: Error?
            while Date() < end {
                do { try Control.shared.checkPaused() } catch { stopped = error; break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try await stream.stopCapture()
            await done.wait(timeout: 5)
            if let stopped {
                // A recording cut short by Lock or Pause is deleted, not left for anyone to read.
                try? FileManager.default.removeItem(at: url)
                throw stopped
            }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ["path": url.path, "bytes": size, "displayId": Int(d.id), "seconds": seconds]
    }
}

@available(macOS 15.0, *)
private final class RecordingDone: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private let sem = DispatchSemaphore(value: 0)
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { sem.signal() }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { sem.signal() }
    func wait(timeout: Double) async {
        let s = sem
        await withCheckedContinuation { c in
            DispatchQueue.global().async { _ = s.wait(timeout: .now() + timeout); c.resume() }
        }
    }
}
