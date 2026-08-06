import AppKit

/// Deep links into System Settings' Privacy & Security panes.
///
/// One place, because every permission Nod asks for needs the same escape hatch:
/// macOS shows a TCC prompt once per app version, so a user who declined can
/// only be sent to the pane by hand. Written per permission it was the same
/// three lines four times over, differing in one query string.
enum SystemSettings {
    /// `pane` is the anchor macOS uses for a Privacy & Security section —
    /// `Privacy_Microphone`, `Privacy_Calendars`, `Privacy_Accessibility`.
    static func open(privacyPane pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
