import ApplicationServices
import Foundation

/// Gate for the Accessibility (`AXUIElement`) TCC permission.
///
/// Separate from Screen Recording: reading another app's element tree needs
/// this grant even though we already capture that app's audio. macOS shows the
/// prompt only once per app version, so a user who declined has to be sent to
/// System Settings by hand.
enum AccessibilityAccess {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Asks the system to show the grant prompt. Returns the state *before* the
    /// user answers — the prompt is asynchronous, and the answer only shows up
    /// on a later `isTrusted` read, which is why every caller so far discards it.
    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openSystemSettings() {
        SystemSettings.open(privacyPane: "Privacy_Accessibility")
    }
}
