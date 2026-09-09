import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

/// Bindable global actions. Each maps to a stable Carbon hotkey id and its
/// own persisted combo, so they all funnel through the one installed event
/// handler — differentiated by id — instead of one manager per hotkey.
enum HotkeyAction: String, CaseIterable, Identifiable {
    case togglePanel
    /// Ask Nod from anywhere. Persisted under the quick panel's old slug and
    /// id, which this replaced, so a custom binding survives the rename.
    case askNod
    /// Speak a question while the key is held; the notch answers when it is
    /// let go. Press and release both matter, which is why it is its own
    /// action rather than a mode of `askNod`.
    case holdToAsk

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
        case .askNod: 3
        case .holdToAsk: 4
        }
    }

    /// UserDefaults slug, kept stable so an upgrading user's existing custom
    /// binding is read back unchanged.
    private var slug: String {
        switch self {
        case .togglePanel: "togglePanel"
        case .askNod: "launcher"
        case .holdToAsk: "holdToAsk"
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
        case .askNod: .init(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey))
        // One hand, one key, held. ⌘T was the first choice and it is "new
        // tab" in every browser: a person asking about a Jira page got a blank
        // tab instead. ⌥ with a letter is bound by almost nothing, and ⌥Space
        // — the other voice apps' default — is Raycast's and Alfred's.
        case .holdToAsk: .init(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey))
        }
    }

    var settingsLabel: String {
        switch self {
        case .togglePanel: "Show / hide panel"
        case .askNod: "Ask Nod"
        case .holdToAsk: "Hold to ask by voice"
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
    /// Fired on the main actor when a registered hotkey is let go. Every
    /// action reports it; only the held ones listen.
    var onRelease: ((HotkeyAction) -> Void)?

    // 'Snod' fourCC — unique signature so our handler ignores other apps'
    // hotkey events that might be routed to the dispatcher target.
    private static let signature: OSType = 0x536e6f64

    private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?

    /// Constructing registers the Carbon hotkeys immediately — create exactly
    /// one instance, in `applicationDidFinishLaunching`.
    init() {
        for action in Self.registered {
            combos[action] = loadCombo(action) ?? action.defaultCombo
        }
        installEventHandler()
        Self.registered.forEach { register($0) }
    }

    /// The actions this build actually listens for. `holdToAsk` is held back
    /// from released builds along with the voice ask it triggers: a Carbon
    /// hotkey registered for a feature that answers nothing takes ⌥T away from
    /// whatever else the person had on it.
    static var registered: [HotkeyAction] {
        #if DEBUG || NOD_SANDBOX
            HotkeyAction.allCases
        #else
            HotkeyAction.allCases.filter { $0 != .holdToAsk }
        #endif
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
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
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
            let released = GetEventKind(eventRef) == UInt32(kEventHotKeyReleased)
            DispatchQueue.main.async {
                if released {
                    manager.onRelease?(action)
                } else {
                    manager.onTrigger?(action)
                }
            }
            return noErr
        }
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            handler,
            specs.count,
            &specs,
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
    /// One cap per key, drawn where the combo is taught rather than named:
    /// the modifier glyph with its word under it, then the key itself.
    var keyCaps: [(symbol: String, name: String?)] {
        var caps: [(symbol: String, name: String?)] = []
        if modifiers & UInt32(controlKey) != 0 { caps.append(("⌃", "control")) }
        if modifiers & UInt32(optionKey) != 0 { caps.append(("⌥", "option")) }
        if modifiers & UInt32(shiftKey) != 0 { caps.append(("⇧", "shift")) }
        if modifiers & UInt32(cmdKey) != 0 { caps.append(("⌘", "command")) }
        caps.append((keyName(keyCode), nil))
        return caps
    }

    /// User-facing glyph string e.g. "⌘⇧S".
    var displayString: String {
        keyCaps.map(\.symbol).joined()
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
