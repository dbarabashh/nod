import Foundation
import Carbon.HIToolbox
import Combine

/// Global hotkey for triggering Suggest reply during a meeting. Uses the
/// Carbon `RegisterEventHotKey` API because `NSEvent.addGlobalMonitor` only
/// observes — it doesn't intercept — and `.keyboardShortcut` on a
/// `.nonactivatingPanel` rarely fires.
@MainActor
final class HotkeyManager: ObservableObject {
    struct Combo: Equatable {
        /// Hardware key code (matches `NSEvent.keyCode` and Carbon's `kVK_*`).
        let keyCode: UInt32
        /// Carbon modifier mask: `cmdKey | shiftKey | optionKey | controlKey`.
        let modifiers: UInt32
    }

    static let shared = HotkeyManager()

    @Published private(set) var combo: Combo

    /// Fired on the main actor when the registered hotkey is pressed.
    var onTrigger: (() -> Void)?

    // 'Snod' fourCC — unique signature so our handler ignores other apps'
    // hotkey events that might be routed to the dispatcher target.
    private static let signature: OSType = 0x536e6f64
    private static let hotKeyID: UInt32 = 1

    private static let keyCodeKey = "hotkey.suggest.keyCode"
    private static let modifiersKey = "hotkey.suggest.modifiers"

    static let defaultCombo = Combo(
        keyCode: UInt32(kVK_ANSI_S),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.keyCodeKey) != nil {
            let kc = UInt32(defaults.integer(forKey: Self.keyCodeKey))
            let mods = UInt32(defaults.integer(forKey: Self.modifiersKey))
            self.combo = Combo(keyCode: kc, modifiers: mods)
        } else {
            self.combo = Self.defaultCombo
        }

        installEventHandler()
        register()
    }

    func setCombo(_ new: Combo) {
        guard new != combo else { return }
        let previous = combo
        combo = new
        UserDefaults.standard.set(Int(new.keyCode), forKey: Self.keyCodeKey)
        UserDefaults.standard.set(Int(new.modifiers), forKey: Self.modifiersKey)
        unregister()
        if !register() {
            // Roll back if the system rejected the new combo (already taken
            // by another app, etc.) — better stale-but-working than nothing.
            combo = previous
            UserDefaults.standard.set(Int(previous.keyCode), forKey: Self.keyCodeKey)
            UserDefaults.standard.set(Int(previous.modifiers), forKey: Self.modifiersKey)
            _ = register()
        }
    }

    func resetToDefault() {
        setCombo(Self.defaultCombo)
    }

    @discardableResult
    private func register() -> Bool {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            id,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
            Log.ui.info("hotkey registered keyCode=\(combo.keyCode) mods=\(combo.modifiers)")
            return true
        }
        Log.ui.error("RegisterEventHotKey failed status=\(status)")
        return false
    }

    private func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installEventHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        var ref: EventHandlerRef?
        let handler: EventHandlerUPP = { _, eventRef, userData in
            guard let userData, let eventRef else { return noErr }
            var hkID = EventHotKeyID()
            let result = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            guard result == noErr else { return result }
            if hkID.id == HotkeyManager.hotKeyID && hkID.signature == HotkeyManager.signature {
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.onTrigger?()
                }
            }
            return noErr
        }
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            handler,
            1,
            &spec,
            pointer,
            &ref
        )
        if status == noErr {
            eventHandlerRef = ref
        } else {
            Log.ui.error("InstallEventHandler failed status=\(status)")
        }
    }
}

// MARK: - Display

extension HotkeyManager.Combo {
    /// User-facing glyph string e.g. "⌘⇧S".
    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += keyName(keyCode)
        return s
    }
}

/// Best-effort keyCode → printable name. Covers ANSI alphanumerics, common
/// punctuation, and the function/navigation keys most users would bind.
private func keyName(_ keyCode: UInt32) -> String {
    switch Int(keyCode) {
    case kVK_ANSI_A: return "A"
    case kVK_ANSI_B: return "B"
    case kVK_ANSI_C: return "C"
    case kVK_ANSI_D: return "D"
    case kVK_ANSI_E: return "E"
    case kVK_ANSI_F: return "F"
    case kVK_ANSI_G: return "G"
    case kVK_ANSI_H: return "H"
    case kVK_ANSI_I: return "I"
    case kVK_ANSI_J: return "J"
    case kVK_ANSI_K: return "K"
    case kVK_ANSI_L: return "L"
    case kVK_ANSI_M: return "M"
    case kVK_ANSI_N: return "N"
    case kVK_ANSI_O: return "O"
    case kVK_ANSI_P: return "P"
    case kVK_ANSI_Q: return "Q"
    case kVK_ANSI_R: return "R"
    case kVK_ANSI_S: return "S"
    case kVK_ANSI_T: return "T"
    case kVK_ANSI_U: return "U"
    case kVK_ANSI_V: return "V"
    case kVK_ANSI_W: return "W"
    case kVK_ANSI_X: return "X"
    case kVK_ANSI_Y: return "Y"
    case kVK_ANSI_Z: return "Z"
    case kVK_ANSI_0: return "0"
    case kVK_ANSI_1: return "1"
    case kVK_ANSI_2: return "2"
    case kVK_ANSI_3: return "3"
    case kVK_ANSI_4: return "4"
    case kVK_ANSI_5: return "5"
    case kVK_ANSI_6: return "6"
    case kVK_ANSI_7: return "7"
    case kVK_ANSI_8: return "8"
    case kVK_ANSI_9: return "9"
    case kVK_Space: return "Space"
    case kVK_Return: return "↩"
    case kVK_Tab: return "⇥"
    case kVK_Escape: return "⎋"
    case kVK_Delete: return "⌫"
    case kVK_LeftArrow: return "←"
    case kVK_RightArrow: return "→"
    case kVK_UpArrow: return "↑"
    case kVK_DownArrow: return "↓"
    case kVK_F1: return "F1"
    case kVK_F2: return "F2"
    case kVK_F3: return "F3"
    case kVK_F4: return "F4"
    case kVK_F5: return "F5"
    case kVK_F6: return "F6"
    case kVK_F7: return "F7"
    case kVK_F8: return "F8"
    case kVK_F9: return "F9"
    case kVK_F10: return "F10"
    case kVK_F11: return "F11"
    case kVK_F12: return "F12"
    case kVK_F13: return "F13"
    case kVK_F14: return "F14"
    case kVK_F15: return "F15"
    case kVK_F16: return "F16"
    case kVK_F17: return "F17"
    case kVK_F18: return "F18"
    case kVK_F19: return "F19"
    case kVK_ANSI_Period: return "."
    case kVK_ANSI_Comma: return ","
    case kVK_ANSI_Slash: return "/"
    case kVK_ANSI_Semicolon: return ";"
    case kVK_ANSI_Quote: return "'"
    case kVK_ANSI_LeftBracket: return "["
    case kVK_ANSI_RightBracket: return "]"
    case kVK_ANSI_Backslash: return "\\"
    case kVK_ANSI_Minus: return "-"
    case kVK_ANSI_Equal: return "="
    case kVK_ANSI_Grave: return "`"
    default: return "?"
    }
}

// MARK: - Notification

extension Notification.Name {
    static let nodSuggestHotkey = Notification.Name("nod.hotkey.suggestReply")
}
