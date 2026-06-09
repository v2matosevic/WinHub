import AppKit
import Carbon.HIToolbox

/// Global hotkeys for keyboard snapping — the Win+Arrow analog, bound to
/// ⌃⌥ + arrows (the convention Rectangle established, chosen to avoid app
/// shortcut collisions). Carbon's `RegisterEventHotKey` is the zero-dependency
/// way to get system-wide hotkeys: no event tap, no extra permissions.
final class SnapHotkeys {
    enum Action: UInt32 {
        case left = 1       // ⌃⌥←  left half
        case right = 2      // ⌃⌥→  right half
        case maximize = 3   // ⌃⌥↑  maximize
        case restore = 4    // ⌃⌥↓  restore pre-snap frame
    }

    var onAction: ((Action) -> Void)?

    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    func register() {
        guard handler == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        // The handler is a C function pointer, so it can't capture — `userData`
        // carries the (unretained) SnapHotkeys, kept alive by its owning module.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let hotkeys = Unmanaged<SnapHotkeys>.fromOpaque(userData).takeUnretainedValue()
            if let action = Action(rawValue: hotKeyID.id) { hotkeys.onAction?(action) }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)

        let signature: OSType = 0x5748_4B53   // 'WHKS'
        let bindings: [(Action, Int)] = [
            (.left,     kVK_LeftArrow),
            (.right,    kVK_RightArrow),
            (.maximize, kVK_UpArrow),
            (.restore,  kVK_DownArrow),
        ]
        for (action, keyCode) in bindings {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(keyCode), UInt32(controlKey | optionKey),
                                EventHotKeyID(signature: signature, id: action.rawValue),
                                GetApplicationEventTarget(), 0, &ref)
            if let ref { hotKeys.append(ref) }
        }
    }

    func unregister() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
