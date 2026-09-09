import Foundation

/// What `open_url`/`open_app` (the live voice session's two non-mutating
/// tools — see `realtime.ts`) are actually allowed to do. Pure and
/// table-driven for the same reason `QuestionIntent` is: there is no model
/// call here, nothing here mutates anything, and every rule the tool
/// descriptions promise the model is enforced again here rather than trusted.
enum VoiceOpenActions {
    /// http(s) only. The model is told never to invent a URL, but the tool
    /// boundary is what actually stops a `file://`, `javascript:`, or
    /// arbitrary custom scheme from ever reaching `NSWorkspace` — a
    /// description is a request, not a guarantee.
    static func validatedURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    /// Where Finder itself looks for an app — nothing this doesn't already
    /// search.
    static let standardApplicationDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    ]

    /// Resolves a spoken app name to an installed `.app` bundle — never a
    /// path the model supplied itself. Exact name wins over a partial one,
    /// so "Settings" still reaches "System Settings.app" without a looser
    /// match shadowing an app whose name is a real, exact hit.
    static func resolveApplication(
        named name: String,
        in directories: [URL] = standardApplicationDirectories,
        fileManager: FileManager = .default
    ) -> URL? {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        var exact: URL?
        var partial: URL?
        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            else { continue }
            for entry in entries where entry.pathExtension == "app" {
                let appName = entry.deletingPathExtension().lastPathComponent
                if appName.caseInsensitiveCompare(query) == .orderedSame {
                    exact = entry
                } else if partial == nil, appName.range(of: query, options: .caseInsensitive) != nil {
                    partial = entry
                }
            }
        }
        return exact ?? partial
    }
}
