import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Button that, when activated, captures the next modifier+key combo via a
/// local NSEvent monitor and writes it back to `HotkeyManager`.
struct HotkeyRecorderView: View {
    @ObservedObject var hotkey: HotkeyManager
    let action: HotkeyAction
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button(action: toggleRecording) {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(isRecording
                            ? Color(red: 0.95, green: 0.45, blue: 0.50)
                            : .white.opacity(0.92))
                        .frame(minWidth: 96)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.white.opacity(isRecording ? 0.04 : 0.06))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(
                                            isRecording
                                                ? Color(red: 0.95, green: 0.45, blue: 0.50).opacity(0.6)
                                                : Color.white.opacity(0.14),
                                            lineWidth: 0.8
                                        )
                                )
                        )
                }
                .buttonStyle(.plain)

                Button("Reset") {
                    cancelRecording()
                    hotkey.resetToDefault(for: action)
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.95, green: 0.55, blue: 0.55))
            }
        }
        .onDisappear(perform: cancelRecording)
    }

    private var label: String {
        if isRecording { return "Press keys…" }
        return hotkey.combo(for: action).displayString
    }

    private func toggleRecording() {
        if isRecording {
            cancelRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        error = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil
        }
    }

    private func cancelRecording() {
        isRecording = false
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .flagsChanged {
            // Wait for an actual key press, not just modifier-down.
            return
        }
        // Esc cancels recording without changing the combo.
        if event.keyCode == kVK_Escape {
            cancelRecording()
            return
        }

        var carbonMods: UInt32 = 0
        if event.modifierFlags.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.option)  { carbonMods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { carbonMods |= UInt32(controlKey) }

        guard carbonMods != 0 else {
            error = "Hotkey needs at least one modifier (⌘ / ⌥ / ⌃ / ⇧)."
            return
        }

        let new = HotkeyManager.Combo(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonMods
        )
        switch hotkey.setCombo(new, for: action) {
        case .ok:
            error = nil
        case let .conflict(other):
            error = "Already used by “\(other.settingsLabel)”. Pick another."
        case .rejectedBySystem:
            error = "That shortcut is already used by another app. Pick another."
        }
        cancelRecording()
    }
}
