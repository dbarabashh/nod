import AppKit
import Foundation

/// An app a screen observation came from, resolved from its bundle id to
/// something showable — a name and an icon.
struct AppIdentity: Equatable, Identifiable {
    let bundleID: String
    let name: String
    let path: String?

    var id: String {
        bundleID
    }
}

/// Bundle id → name + icon, for attributing an answer to the apps it read.
///
/// Separate from `InstalledApps`, which walks the filesystem to build the
/// privacy list: here we resolve one known id at a time, and the answer is
/// needed while a view is rendering.
@MainActor
enum AppDirectory {
    private static var identities: [String: AppIdentity] = [:]
    private static var icons: [String: NSImage] = [:]

    static func identity(forBundleID bundleID: String) -> AppIdentity {
        if let cached = identities[bundleID] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let identity = AppIdentity(
            bundleID: bundleID,
            name: url.flatMap(displayName(at:)) ?? fallbackName(for: bundleID),
            path: url?.path
        )
        identities[bundleID] = identity
        return identity
    }

    /// Cached: SwiftUI asks for this on every body evaluation, and each miss is
    /// a disk hit for the icon resource.
    static func icon(for identity: AppIdentity) -> NSImage? {
        if let cached = icons[identity.bundleID] { return cached }
        guard let path = identity.path else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[identity.bundleID] = icon
        return icon
    }

    private static func displayName(at url: URL) -> String? {
        guard let bundle = Bundle(url: url) else { return nil }
        let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary
        if let name = info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// An app that has since been uninstalled still has observations on record.
    /// "com.tinyspeck.slackmacgap" is unreadable; its last segment isn't.
    static func fallbackName(for bundleID: String) -> String {
        let segment = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return segment.isEmpty ? bundleID : segment.capitalized
    }
}
