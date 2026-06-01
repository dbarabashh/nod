import Foundation
import Carbon.HIToolbox
import Combine
import AppKit

/// Bindable global actions. Each maps to a stable Carbon hotkey id and its
/// own persisted combo, so they all funnel through the one installed event
/// handler — differentiated by id — instead of one manager per hotkey.
enum HotkeyAction: String, CaseIterable, Identifiable {
    case suggestReply
    case togglePanel

    var id: String { rawValue }

    init?(hotKeyID: UInt32) {
        guard let match = Self.allCases.first(where: { $0.hotKeyID == hotKeyID }) else { return nil }
        self = match
    }

    /// Stable Carbon `EventHotKeyID.id`. suggestReply == 1 to match what was
    /// already registered before this became multi-action; new actions take
    /// fresh ids and must never reuse a retired one.
    var hotKeyID: UInt32 {
        switch self {
        case .suggestReply: return 1
        case .togglePanel:  return 2
        }
    }

    /// UserDefaults slug. suggestReply keeps the legacy "suggest" slug so an
    /// upgrading user's existing custom binding is read back unchanged.
    private var slug: String {
        switch self {
        case .suggestReply: return "suggest"
        case .togglePanel:  return "togglePanel"
        }
    }
    var keyCodeKey: String   { "hotkey.\(slug).keyCode" }
    var modifiersKey: String { "hotkey.\(slug).modifiers" }

    /// Defaults stay ⌘⇧<letter> — conflict-safe. Bare ⌘S / ⌘H are reserved
    /// system-wide (Save / Hide) and a global hotkey would hijack them.
    var defaultCombo: HotkeyManager.Combo {
        switch self {
        case .suggestReply: return .init(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey))
        case .togglePanel:  return .init(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey | shiftKey))
        }
    }

    var settingsLabel: String {
        switch self {
        case .suggestReply: return "Suggest reply"
        case .togglePanel:  return "Show / hide panel"
        }
    }
}

/// Global hotkeys via the Carbon `RegisterEventHotKey` API — `NSEvent`
/// monitors only observe, they don't intercept, and `.keyboardShortcut` on a
/// `.nonactivatingPanel` rarely fires. One handler is installed once and
/// dispatches to the matching `HotkeyAction` by hotkey id.
@MainActor
final class HotkeyManager: ObservableObject {
    struct Combo: Equatable {
        /// Hardware key code (matches `NSEvent.keyCode` and Carbon's `kVK_*`).
        let keyCode: UInt32
        /// Carbon modifier mask: `cmdKey | shiftKey | optionKey | controlKey`.
        let modifiers: UInt32
    }

    /// Outcome of a rebind, so the recorder can show a precise reason.
    enum SetComboResult: Equatable {
        case ok
        case conflict(HotkeyAction)   // already bound to another Nod action
        case rejectedBySystem         // RegisterEventHotKey failed (claimed elsewhere)
    }

    static let shared = HotkeyManager()

    @Published private(set) var combos: [HotkeyAction: Combo] = [:]

    /// Fired on the main actor when a registered hotkey is pressed.
    var onTrigger: ((HotkeyAction) -> Void)?

    // 'Snod' fourCC — unique signature so our handler ignores other apps'
    // hotkey events that might be routed to the dispatcher target.
    private static let signature: OSType = 0x536e6f64

    private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?

    private init() {
        for action in HotkeyAction.allCases {
            combos[action] = loadCombo(action) ?? action.defaultCombo
        }
        installEventHandler()
        HotkeyAction.allCases.forEach { register($0) }
    }

    func combo(for action: HotkeyAction) -> Combo {
        combos[action] ?? action.defaultCombo
    }

    @discardableResult
    func setCombo(_ new: Combo, for action: HotkeyAction) -> SetComboResult {
        guard new != combo(for: action) else { return .ok }
        if let clash = combos.first(where: { $0.key != action && $0.value == new })?.key {
            return .conflict(clash)
        }
        let previous = combo(for: action)
        combos[action] = new
        persist(new, action)
        unregister(action)
        if register(action) { return .ok }
        // System rejected the combo (already claimed by another app) — roll
        // back to the previous working binding.
        combos[action] = previous
        persist(previous, action)
        _ = register(action)
        return .rejectedBySystem
    }

    func resetToDefault(for action: HotkeyAction) {
        _ = setCombo(action.defaultCombo, for: action)
    }

    private func loadCombo(_ action: HotkeyAction) -> Combo? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: action.keyCodeKey) != nil else { return nil }
        return Combo(
            keyCode: UInt32(defaults.integer(forKey: action.keyCodeKey)),
            modifiers: UInt32(defaults.integer(forKey: action.modifiersKey))
        )
    }

    private func persist(_ combo: Combo, _ action: HotkeyAction) {
        UserDefaults.standard.set(Int(combo.keyCode), forKey: action.keyCodeKey)
        UserDefaults.standard.set(Int(combo.modifiers), forKey: action.modifiersKey)
    }

    @discardableResult
    private func register(_ action: HotkeyAction) -> Bool {
        var ref: EventHotKeyRef?
        let combo = combo(for: action)
        let id = EventHotKeyID(signature: Self.signature, id: action.hotKeyID)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            id,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if status == noErr {
            refs[action] = ref
            Log.ui.info("hotkey registered \(action.rawValue) keyCode=\(combo.keyCode) mods=\(combo.modifiers)")
            return true
        }
        Log.ui.error("RegisterEventHotKey failed \(action.rawValue) status=\(status)")
        return false
    }

    private func unregister(_ action: HotkeyAction) {
        if let ref = refs[action] {
            UnregisterEventHotKey(ref)
            refs[action] = nil
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
            guard result == noErr, hkID.signature == HotkeyManager.signature else { return result }
            guard let action = HotkeyAction(hotKeyID: hkID.id) else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                manager.onTrigger?(action)
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

    /// `(keyEquivalent, modifierMask)` for displaying this combo on an
    /// `NSMenuItem`, or nil for keys we don't render as a menu equivalent
    /// (function / navigation keys). The letter is lowercased — Shift is
    /// carried by the mask, which is how AppKit renders e.g. "⇧⌘H".
    var menuKeyEquivalent: (String, NSEvent.ModifierFlags)? {
        guard let key = menuKeyEquivalentCharacter(keyCode) else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return (key, flags)
    }
}

/// The literal character an `NSMenuItem.keyEquivalent` expects, for the keys a
/// user is likely to bind. Returns nil for function/navigation keys (whose
/// equivalents need special unichar constants) — those simply render without
/// a shortcut rather than a wrong one.
private func menuKeyEquivalentCharacter(_ keyCode: UInt32) -> String? {
    switch Int(keyCode) {
    case kVK_ANSI_A: return "a"
    case kVK_ANSI_B: return "b"
    case kVK_ANSI_C: return "c"
    case kVK_ANSI_D: return "d"
    case kVK_ANSI_E: return "e"
    case kVK_ANSI_F: return "f"
    case kVK_ANSI_G: return "g"
    case kVK_ANSI_H: return "h"
    case kVK_ANSI_I: return "i"
    case kVK_ANSI_J: return "j"
    case kVK_ANSI_K: return "k"
    case kVK_ANSI_L: return "l"
    case kVK_ANSI_M: return "m"
    case kVK_ANSI_N: return "n"
    case kVK_ANSI_O: return "o"
    case kVK_ANSI_P: return "p"
    case kVK_ANSI_Q: return "q"
    case kVK_ANSI_R: return "r"
    case kVK_ANSI_S: return "s"
    case kVK_ANSI_T: return "t"
    case kVK_ANSI_U: return "u"
    case kVK_ANSI_V: return "v"
    case kVK_ANSI_W: return "w"
    case kVK_ANSI_X: return "x"
    case kVK_ANSI_Y: return "y"
    case kVK_ANSI_Z: return "z"
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
    default: return nil
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
