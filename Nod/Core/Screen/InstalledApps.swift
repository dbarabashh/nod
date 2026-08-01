import AppKit
import Foundation

/// One app the user can put off-limits, as shown in the privacy list.
struct InstalledApp: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let path: String

    var id: String {
        bundleID
    }

    /// Cached in `AppDirectory`, not fetched here: this renders once per row in
    /// a list of every installed app, and an uncached lookup is a disk hit per
    /// row per body pass.
    @MainActor
    var icon: NSImage? {
        AppDirectory.icon(for: AppIdentity(bundleID: bundleID, name: name, path: path))
    }
}

/// Enumerates the apps installed on this Mac so the privacy list can offer
/// every one of them, not just whatever happens to be running.
enum InstalledApps {
    private static let searchPaths = [
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/Applications/Utilities",
        NSHomeDirectory() + "/Applications"
    ]

    /// Blocking (it stats the filesystem) — call it off the main actor.
    static func load() -> [InstalledApp] {
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        let own = Bundle.main.bundleIdentifier

        for directory in searchPaths {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for entry in contents where entry.hasSuffix(".app") {
                let path = directory + "/" + entry
                guard let bundle = Bundle(path: path),
                      let bundleID = bundle.bundleIdentifier,
                      bundleID != own,
                      seen.insert(bundleID).inserted
                else { continue }
                apps.append(InstalledApp(bundleID: bundleID, name: AppDirectory.displayName(of: bundle, at: path), path: path))
            }
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Case- and diacritic-insensitive name match for the search field.
    static func matches(_ app: InstalledApp, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return app.name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
