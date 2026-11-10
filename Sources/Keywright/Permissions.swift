// TCC permission checks and the requests/Settings links behind the menu's permission buttons.
import AVFoundation
import AppKit
import ApplicationServices
import IOKit.hid
import ScreenCaptureKit

enum Permission: String, CaseIterable, Identifiable {
    case accessibility = "Accessibility"
    case screenRecording = "Screen Recording"
    case inputMonitoring = "Input Monitoring"
    case microphone = "Microphone"
    case camera = "Camera"
    var id: String { rawValue }

    var granted: Bool {
        switch self {
        case .accessibility: return AXIsProcessTrusted() && CGPreflightPostEventAccess()
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .inputMonitoring: return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .camera: return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        }
    }

    var settingsURL: URL {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .microphone: anchor = "Privacy_Microphone"
        case .camera: anchor = "Privacy_Camera"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// Shows the system prompt (which also adds Keywright to the list) when not yet granted,
    /// then opens the matching System Settings pane. The user decides; nothing is clicked for them.
    func request() {
        if !granted {
            switch self {
            case .accessibility:
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            case .screenRecording:
                _ = CGRequestScreenCaptureAccess()
                // Newer macOS only lists an app once it actually asks ScreenCaptureKit for content.
                SCShareableContent.getWithCompletionHandler { _, _ in }
            case .inputMonitoring:
                _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            case .microphone:
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            case .camera:
                AVCaptureDevice.requestAccess(for: .video) { _ in }
            }
        }
        NSWorkspace.shared.open(settingsURL)
    }

    static var json: [String: Any] {
        [
            "accessibility": Permission.accessibility.granted,
            "screenRecording": Permission.screenRecording.granted,
            "inputMonitoring": Permission.inputMonitoring.granted,
            "microphone": MediaAccess.status(.audio),
            "camera": MediaAccess.status(.video),
        ]
    }
}
