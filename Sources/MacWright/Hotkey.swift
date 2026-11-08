// Global hotkey ⌃⌥⌘⎋ (Carbon RegisterEventHotKey: needs no permission) toggles Pause.
import Carbon
import Foundation

enum Hotkey {
    private static var ref: EventHotKeyRef?
    private static var handler: (() -> Void)?

    static func register(_ action: @escaping () -> Void) {
        handler = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { Hotkey.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4D435752) /* 'MCWR' */, id: 1)
        RegisterEventHotKey(UInt32(kVK_Escape), UInt32(controlKey | optionKey | cmdKey), id,
                            GetApplicationEventTarget(), 0, &ref)
    }
}
