import AppKit

extension NSPasteboard {
    /// Replace the general pasteboard's contents with a single plain-text
    /// string — the clear-then-set pair every copy button needs. Centralised so
    /// the AI-chat, response, transcript, share-link, and connector-link copy
    /// actions can't drift.
    static func copyText(_ string: String) {
        general.clearContents()
        general.setString(string, forType: .string)
    }
}
