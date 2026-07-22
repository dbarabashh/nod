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

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: path)
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
                apps.append(InstalledApp(bundleID: bundleID, name: displayName(of: bundle, path: path), path: path))
            }
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func displayName(of bundle: Bundle, path: String) -> String {
        let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary
        if let name = info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String {
            return name
        }
        return (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
    }

    /// Case- and diacritic-insensitive name match for the search field.
    static func matches(_ app: InstalledApp, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return app.name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
