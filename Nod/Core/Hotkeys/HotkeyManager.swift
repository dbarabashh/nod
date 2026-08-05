import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

/// Bindable global actions. Each maps to a stable Carbon hotkey id and its
/// own persisted combo, so they all funnel through the one installed event
/// handler — differentiated by id — instead of one manager per hotkey.
enum HotkeyAction: String, CaseIterable, Identifiable {
    case togglePanel
    case openLauncher

    var id: String {
        rawValue
    }

    init?(hotKeyID: UInt32) {
        guard let match = Self.allCases.first(where: { $0.hotKeyID == hotKeyID }) else { return nil }
        self = match
    }

    /// Stable Carbon `EventHotKeyID.id`. A retired action's id is never reused
    /// — 1 belonged to the mid-call "Suggest reply" binding.
    var hotKeyID: UInt32 {
        switch self {
        case .togglePanel: 2
        case .openLauncher: 3
        }
    }

    /// UserDefaults slug, kept stable so an upgrading user's existing custom
    /// binding is read back unchanged.
    private var slug: String {
        switch self {
        case .togglePanel: "togglePanel"
        case .openLauncher: "launcher"
        }
    }

    var keyCodeKey: String {
        "hotkey.\(slug).keyCode"
    }

    var modifiersKey: String {
        "hotkey.\(slug).modifiers"
    }

    /// Defaults stay ⌘⇧<letter> — conflict-safe. Bare ⌘S / ⌘H are reserved
    /// system-wide (Save / Hide) and a global hotkey would hijack them.
    var defaultCombo: HotkeyManager.Combo {
        switch self {
        case .togglePanel: .init(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey | shiftKey))
        // ⌘Space is Spotlight and ⌥Space is Raycast's own; ⌘⇧K stays clear of
        // both and matches the ⌘K command-bar convention.
        case .openLauncher: .init(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey))
        }
    }

    var settingsLabel: String {
        switch self {
        case .togglePanel: "Show / hide panel"
        case .openLauncher: "Search & ask"
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
        case conflict(HotkeyAction) // already bound to another Nod action
        case rejectedBySystem // RegisterEventHotKey failed (claimed elsewhere)
    }

    @Published private(set) var combos: [HotkeyAction: Combo] = [:]

    /// Fired on the main actor when a registered hotkey is pressed.
    var onTrigger: ((HotkeyAction) -> Void)?

    // 'Snod' fourCC — unique signature so our handler ignores other apps'
    // hotkey events that might be routed to the dispatcher target.
    private static let signature: OSType = 0x536e6f64

    private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?

    /// Constructing registers the Carbon hotkeys immediately — create exactly
    /// one instance, in `applicationDidFinishLaunching`.
    init() {
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
    case kVK_ANSI_A: "a"
    case kVK_ANSI_B: "b"
    case kVK_ANSI_C: "c"
    case kVK_ANSI_D: "d"
    case kVK_ANSI_E: "e"
    case kVK_ANSI_F: "f"
    case kVK_ANSI_G: "g"
    case kVK_ANSI_H: "h"
    case kVK_ANSI_I: "i"
    case kVK_ANSI_J: "j"
    case kVK_ANSI_K: "k"
    case kVK_ANSI_L: "l"
    case kVK_ANSI_M: "m"
    case kVK_ANSI_N: "n"
    case kVK_ANSI_O: "o"
    case kVK_ANSI_P: "p"
    case kVK_ANSI_Q: "q"
    case kVK_ANSI_R: "r"
    case kVK_ANSI_S: "s"
    case kVK_ANSI_T: "t"
    case kVK_ANSI_U: "u"
    case kVK_ANSI_V: "v"
    case kVK_ANSI_W: "w"
    case kVK_ANSI_X: "x"
    case kVK_ANSI_Y: "y"
    case kVK_ANSI_Z: "z"
    case kVK_ANSI_0: "0"
    case kVK_ANSI_1: "1"
    case kVK_ANSI_2: "2"
    case kVK_ANSI_3: "3"
    case kVK_ANSI_4: "4"
    case kVK_ANSI_5: "5"
    case kVK_ANSI_6: "6"
    case kVK_ANSI_7: "7"
    case kVK_ANSI_8: "8"
    case kVK_ANSI_9: "9"
    case kVK_ANSI_Period: "."
    case kVK_ANSI_Comma: ","
    case kVK_ANSI_Slash: "/"
    case kVK_ANSI_Semicolon: ";"
    case kVK_ANSI_Quote: "'"
    case kVK_ANSI_LeftBracket: "["
    case kVK_ANSI_RightBracket: "]"
    case kVK_ANSI_Backslash: "\\"
    case kVK_ANSI_Minus: "-"
    case kVK_ANSI_Equal: "="
    case kVK_ANSI_Grave: "`"
    default: nil
    }
}

/// Best-effort keyCode → printable name. Covers ANSI alphanumerics, common
/// punctuation, and the function/navigation keys most users would bind.
private func keyName(_ keyCode: UInt32) -> String {
    switch Int(keyCode) {
    case kVK_ANSI_A: "A"
    case kVK_ANSI_B: "B"
    case kVK_ANSI_C: "C"
    case kVK_ANSI_D: "D"
    case kVK_ANSI_E: "E"
    case kVK_ANSI_F: "F"
    case kVK_ANSI_G: "G"
    case kVK_ANSI_H: "H"
    case kVK_ANSI_I: "I"
    case kVK_ANSI_J: "J"
    case kVK_ANSI_K: "K"
    case kVK_ANSI_L: "L"
    case kVK_ANSI_M: "M"
    case kVK_ANSI_N: "N"
    case kVK_ANSI_O: "O"
    case kVK_ANSI_P: "P"
    case kVK_ANSI_Q: "Q"
    case kVK_ANSI_R: "R"
    case kVK_ANSI_S: "S"
    case kVK_ANSI_T: "T"
    case kVK_ANSI_U: "U"
    case kVK_ANSI_V: "V"
    case kVK_ANSI_W: "W"
    case kVK_ANSI_X: "X"
    case kVK_ANSI_Y: "Y"
    case kVK_ANSI_Z: "Z"
    case kVK_ANSI_0: "0"
    case kVK_ANSI_1: "1"
    case kVK_ANSI_2: "2"
    case kVK_ANSI_3: "3"
    case kVK_ANSI_4: "4"
    case kVK_ANSI_5: "5"
    case kVK_ANSI_6: "6"
    case kVK_ANSI_7: "7"
    case kVK_ANSI_8: "8"
    case kVK_ANSI_9: "9"
    case kVK_Space: "Space"
    case kVK_Return: "↩"
    case kVK_Tab: "⇥"
    case kVK_Escape: "⎋"
    case kVK_Delete: "⌫"
    case kVK_LeftArrow: "←"
    case kVK_RightArrow: "→"
    case kVK_UpArrow: "↑"
    case kVK_DownArrow: "↓"
    case kVK_F1: "F1"
    case kVK_F2: "F2"
    case kVK_F3: "F3"
    case kVK_F4: "F4"
    case kVK_F5: "F5"
    case kVK_F6: "F6"
    case kVK_F7: "F7"
    case kVK_F8: "F8"
    case kVK_F9: "F9"
    case kVK_F10: "F10"
    case kVK_F11: "F11"
    case kVK_F12: "F12"
    case kVK_F13: "F13"
    case kVK_F14: "F14"
    case kVK_F15: "F15"
    case kVK_F16: "F16"
    case kVK_F17: "F17"
    case kVK_F18: "F18"
    case kVK_F19: "F19"
    case kVK_ANSI_Period: "."
    case kVK_ANSI_Comma: ","
    case kVK_ANSI_Slash: "/"
    case kVK_ANSI_Semicolon: ";"
    case kVK_ANSI_Quote: "'"
    case kVK_ANSI_LeftBracket: "["
    case kVK_ANSI_RightBracket: "]"
    case kVK_ANSI_Backslash: "\\"
    case kVK_ANSI_Minus: "-"
    case kVK_ANSI_Equal: "="
    case kVK_ANSI_Grave: "`"
    default: "?"
    }
}
