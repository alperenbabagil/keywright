import XCTest
@testable import KeywrightCore

final class MediaTests: XCTestCase {
    let devices = [
        MediaDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", modelID: "Digital Mic", audio: true, builtIn: true),
        MediaDevice(id: "AppleUSBAudioEngine:Focusrite:Scarlett 2i2", name: "Scarlett 2i2 USB", modelID: "Scarlett 2i2 USB:1235:8210", audio: true),
        MediaDevice(id: "iphone-mic-1", name: "alperen’s iPhone Microphone", modelID: "iPhone12,1", audio: true),
        MediaDevice(id: "FaceTime-1", name: "MacBook Pro Camera", modelID: "FaceTime HD Camera", video: true, builtIn: true),
        // As listed live: Desk View comes before the main camera, for the Mac and the iPhone.
        MediaDevice(id: "desk-1", name: "MacBook Pro Desk View Camera", modelID: "MacBook Pro Desk View Camera", video: true, builtIn: true, deskView: true),
        MediaDevice(id: "iphone-desk-1", name: "alperen’s iPhone Desk View Camera", modelID: "iPhone12,1", video: true, deskView: true),
        MediaDevice(id: "iphone-cam-1", name: "alperen’s iPhone Camera", modelID: "iPhone12,1", video: true),
        MediaDevice(id: "iphone-cam-2", name: "Test iPhone 15 Camera", modelID: "iPhone16,1", video: true),
    ]

    func testDeskViewOnlyWhenNamed() throws {
        XCTAssertEqual(try MediaMatch.resolve("iphone:alperen’s iPhone", in: devices, kind: .video).id, "iphone-cam-1")
        XCTAssertEqual(try MediaMatch.resolve("iphone:alperen", in: devices, kind: .video).id, "iphone-cam-1")
        XCTAssertEqual(try MediaMatch.resolve("iphone:alperen’s iPhone Desk View Camera", in: devices, kind: .video).id, "iphone-desk-1")
        XCTAssertEqual(try MediaMatch.resolve("mac-camera", in: [devices[4], devices[3]], kind: .video).id, "FaceTime-1")
        XCTAssertEqual(try MediaMatch.resolve(nil, in: [devices[4], devices[3]], kind: .video).id, "FaceTime-1")
        XCTAssertEqual(try MediaMatch.resolve("macbook pro desk view", in: devices, kind: .video).id, "desk-1")
        XCTAssertEqual(try MediaMatch.resolve("MacBook Pro", in: devices, kind: .video).id, "FaceTime-1")
    }

    func testDefaultPrefersSystemDefaultThenBuiltIn() throws {
        XCTAssertEqual(try MediaMatch.resolve(nil, in: devices, kind: .audio).id, "BuiltInMicrophoneDevice")
        XCTAssertEqual(try MediaMatch.resolve("default", in: devices, kind: .audio, defaultID: "iphone-mic-1").id, "iphone-mic-1")
        XCTAssertEqual(try MediaMatch.resolve("", in: devices, kind: .video).id, "FaceTime-1")
    }

    func testMacAliases() throws {
        XCTAssertEqual(try MediaMatch.resolve("mac-mic", in: devices, kind: .audio).id, "BuiltInMicrophoneDevice")
        XCTAssertEqual(try MediaMatch.resolve("mac-camera", in: devices, kind: .video).id, "FaceTime-1")
        XCTAssertThrowsError(try MediaMatch.resolve("mac-mic", in: devices, kind: .video))
    }

    func testIPhoneByNameIgnoresApostropheStyleAndSuffix() throws {
        XCTAssertEqual(try MediaMatch.resolve("iphone:alperen's iPhone", in: devices, kind: .video).id, "iphone-cam-1")
        XCTAssertEqual(try MediaMatch.resolve("iphone:alperen’s iphone", in: devices, kind: .audio).id, "iphone-mic-1")
        XCTAssertEqual(try MediaMatch.resolve("iphone:Test iPhone 15", in: devices, kind: .video).id, "iphone-cam-2")
        // Only one iPhone has a microphone, so a bare "iphone" picks it; two have cameras.
        XCTAssertEqual(try MediaMatch.resolve("iphone", in: devices, kind: .audio).id, "iphone-mic-1")
        XCTAssertThrowsError(try MediaMatch.resolve("iphone", in: devices, kind: .video)) { e in
            XCTAssertTrue("\(e)".contains("several iPhones"))
        }
        XCTAssertThrowsError(try MediaMatch.resolve("iphone:nobody", in: devices, kind: .video)) { e in
            XCTAssertTrue("\(e)".contains("Continuity Camera"))
        }
    }

    func testIdNameModelAndSubstring() throws {
        XCTAssertEqual(try MediaMatch.resolve("AppleUSBAudioEngine:Focusrite:Scarlett 2i2", in: devices, kind: .audio).name, "Scarlett 2i2 USB")
        XCTAssertEqual(try MediaMatch.resolve("macbook pro camera", in: devices, kind: .video).id, "FaceTime-1")
        XCTAssertEqual(try MediaMatch.resolve("iPhone16,1", in: devices, kind: .video).id, "iphone-cam-2")
        XCTAssertEqual(try MediaMatch.resolve("scarlett", in: devices, kind: .audio).id, "AppleUSBAudioEngine:Focusrite:Scarlett 2i2")
        // A camera name is not an audio input.
        XCTAssertThrowsError(try MediaMatch.resolve("MacBook Pro Camera", in: devices, kind: .audio))
        XCTAssertThrowsError(try MediaMatch.resolve("camera", in: devices, kind: .video)) { e in
            XCTAssertTrue("\(e)".contains("several devices"))
        }
        XCTAssertThrowsError(try MediaMatch.resolve("nothing", in: devices, kind: .audio)) { e in
            XCTAssertTrue("\(e)".contains("available"))
        }
    }

    func testMuxedCountsAsBoth() throws {
        let d = [MediaDevice(id: "m", name: "Capture Card", modelID: "x", muxed: true)]
        XCTAssertEqual(try MediaMatch.resolve(nil, in: d, kind: .audio).id, "m")
        XCTAssertEqual(try MediaMatch.resolve(nil, in: d, kind: .video).id, "m")
        XCTAssertThrowsError(try MediaMatch.resolve(nil, in: [], kind: .audio))
    }

    func testRecordRequestParsing() throws {
        XCTAssertEqual(try AudioRecordRequest.parse(action: nil, seconds: 5, maxSeconds: nil, id: nil), .blocking(seconds: 5))
        XCTAssertEqual(try AudioRecordRequest.parse(action: "record", seconds: 9999, maxSeconds: nil, id: nil), .blocking(seconds: 600))
        XCTAssertEqual(try AudioRecordRequest.parse(action: "Start", seconds: nil, maxSeconds: nil, id: nil), .start(maxSeconds: 600))
        XCTAssertEqual(try AudioRecordRequest.parse(action: "start", seconds: nil, maxSeconds: 1e6, id: nil), .start(maxSeconds: 3600))
        XCTAssertEqual(try AudioRecordRequest.parse(action: "stop", seconds: nil, maxSeconds: nil, id: "a1"), .stop(id: "a1"))
        XCTAssertEqual(try AudioRecordRequest.parse(action: "list", seconds: nil, maxSeconds: nil, id: nil), .list)
        XCTAssertThrowsError(try AudioRecordRequest.parse(action: nil, seconds: nil, maxSeconds: nil, id: nil))
        XCTAssertThrowsError(try AudioRecordRequest.parse(action: nil, seconds: 0, maxSeconds: nil, id: nil))
        XCTAssertThrowsError(try AudioRecordRequest.parse(action: "start", seconds: 3, maxSeconds: nil, id: nil))
        XCTAssertThrowsError(try AudioRecordRequest.parse(action: "pause", seconds: nil, maxSeconds: nil, id: nil))
    }

    func testLoudStretches() {
        let q = -90.0, l = -20.0
        // 0.1 s windows: loud 0.2-0.5, a 0.2 s gap (bridged), loud 0.7-0.8, a 0.5 s gap, loud 1.3-1.4.
        let levels = [q, q, l, l, -10, q, q, l, q, q, q, q, q, l]
        let s = AudioLevels.loudStretches(levelsDb: levels, windowSeconds: 0.1, thresholdDb: -35)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].start, 0.2, accuracy: 1e-9)
        XCTAssertEqual(s[0].end, 0.8, accuracy: 1e-9)
        XCTAssertEqual(s[0].peakDb, -10)
        XCTAssertEqual(s[1].start, 1.3, accuracy: 1e-9)
        XCTAssertTrue(AudioLevels.loudStretches(levelsDb: [q, q], windowSeconds: 0.1, thresholdDb: -35).isEmpty)
        XCTAssertEqual(AudioLevels.db(0), -160)
        XCTAssertEqual(AudioLevels.db(1), 0)
        XCTAssertEqual(AudioLevels.db(0.1), -20, accuracy: 1e-9)
    }
}
