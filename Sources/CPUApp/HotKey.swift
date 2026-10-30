import Carbon
import Foundation

/// System-wide hotkey via Carbon (no Accessibility permission needed), reporting both
/// press and release so the app can tell push-to-talk from a tap.
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onPress: () -> Void
    private let onRelease: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else {
                return noErr
            }
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
                hotKey.onPress()
            } else {
                hotKey.onRelease()
            }
            return noErr
        }, types.count, &types, context, &handler)
        guard status == noErr else {
            return nil
        }
        let id = EventHotKeyID(signature: OSType(0x4350_5531), id: 1)
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr else {
            if let handler {
                RemoveEventHandler(handler)
            }
            return nil
        }
    }

    deinit {
        if let reference {
            UnregisterEventHotKey(reference)
        }
        if let handler {
            RemoveEventHandler(handler)
        }
    }
}
