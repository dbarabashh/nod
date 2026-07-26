import Foundation

/// An app the user has put off-limits to screen reading.
struct ExcludedApp: Codable, Equatable, Identifiable {
    let bundleID: String
    let name: String

    var id: String {
        bundleID
    }
}

/// The user's screen-reading blocklist: apps and websites Nod must never look
/// inside, whatever else it is allowed to read.
///
/// Deliberately a *blocklist the user controls* rather than a promise in a
/// policy: reading another app's window is only defensible if stopping it is
/// one click away, and the reader consults this before any traversal.
///
/// Stored in `UserDefaults` — a local preference about local behaviour, so it
/// never leaves the machine and cannot be changed from the server.
@MainActor
final class ScreenExclusions: ObservableObject {
    @Published private(set) var apps: [ExcludedApp] = []
    @Published private(set) var websites: [String] = []
    @Published private(set) var categories: Set<WebsiteCategory> = []

    private let defaults: UserDefaults
    private static let appsKey = "screen.exclusions.apps"
    private static let websitesKey = "screen.exclusions.websites"
    private static let categoriesKey = "screen.exclusions.categories"
    /// Legacy flag: "the messenger defaults have been seeded". Read only, to
    /// migrate an install that predates `offeredMessengersKey`.
    private static let seededMessengersKey = "screen.exclusions.seededMessengers"
    /// Every default that has ever been *offered* to this install, whether or
    /// not it is still excluded. A plain "already seeded" flag couldn't tell a
    /// list that had grown from one that hadn't, so a messenger added to the
    /// defaults later never reached anyone who had already run Nod once.
    private static let offeredMessengersKey = "screen.exclusions.offeredMessengers"

    /// Personal messengers, excluded before the user has said anything.
    ///
    /// Ambient capture reads the window you are looking at, and the window
    /// people look at most is a private conversation with someone who never
    /// agreed to any of this. A blocklist that starts empty puts that text in
    /// the index by default and asks the user to notice afterwards.
    ///
    /// Seeded, not hardcoded: it lands in the same list as any other exclusion,
    /// so a user who *wants* their messenger indexed can untick it and it stays
    /// off — see `seedDefaultsIfNeeded`.
    /// Telegram ships under three different identifiers and each one is a
    /// separate entry: matching is by bundle id, so the two that were listed
    /// here left the build most people actually run — `com.tdesktop.Telegram` —
    /// readable by default. A messenger missing from this list is not a
    /// cosmetic gap; it is private conversation in the index.
    static let defaultExcludedMessengers = [
        ExcludedApp(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp"),
        ExcludedApp(bundleID: "com.tdesktop.Telegram", name: "Telegram"),
        ExcludedApp(bundleID: "ru.keepcoder.Telegram", name: "Telegram"),
        ExcludedApp(bundleID: "org.telegram.desktop", name: "Telegram Desktop"),
        ExcludedApp(bundleID: "com.apple.MobileSMS", name: "Messages"),
        ExcludedApp(bundleID: "com.facebook.archon", name: "Messenger"),
        ExcludedApp(bundleID: "com.signal.Signal", name: "Signal"),
        ExcludedApp(bundleID: "org.whispersystems.signal-desktop", name: "Signal"),
        ExcludedApp(bundleID: "com.viber.osx", name: "Viber"),
        ExcludedApp(bundleID: "com.hnc.Discord", name: "Discord")
    ]

    /// What the first version of the list contained. Used only to migrate an
    /// install carrying the old boolean flag: those ids were already offered
    /// once, so one the user removed back then must not come back now.
    private static let firstSeededBundleIDs: Set<String> = [
        "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram",
        "org.telegram.desktop",
        "com.apple.MobileSMS",
        "com.facebook.archon",
        "com.signal.Signal",
        "com.viber.osx",
        "com.hnc.Discord"
    ]

    init(defaults: UserDefaults = .standard, seedDefaults: Bool = true) {
        self.defaults = defaults
        apps = Self.decode([ExcludedApp].self, from: defaults, key: Self.appsKey) ?? []
        websites = Self.decode([String].self, from: defaults, key: Self.websitesKey) ?? []
        categories = Set(Self.decode([WebsiteCategory].self, from: defaults, key: Self.categoriesKey) ?? [])
        if seedDefaults { seedDefaultsIfNeeded() }
    }

    /// Offers each messenger default exactly once, ever.
    ///
    /// Once, so an app the user deliberately removed never comes back. Each,
    /// so a default added in a later version still reaches installs that have
    /// already run — which is what a single "seeded" flag got wrong, leaving
    /// every existing install without the Telegram build most people have.
    private func seedDefaultsIfNeeded() {
        var offered = Set(defaults.stringArray(forKey: Self.offeredMessengersKey) ?? [])
        if offered.isEmpty, defaults.bool(forKey: Self.seededMessengersKey) {
            offered = Self.firstSeededBundleIDs
        }

        let known = Set(apps.map(\.bundleID))
        let added = Self.defaultExcludedMessengers.filter {
            !offered.contains($0.bundleID) && !known.contains($0.bundleID)
        }
        defaults.set(
            offered.union(Self.defaultExcludedMessengers.map(\.bundleID)).sorted(),
            forKey: Self.offeredMessengersKey
        )

        guard !added.isEmpty else { return }
        apps.append(contentsOf: added)
        persistApps()
        Log.screen.info("exclusions: seeded \(added.count) messenger default(s)")
    }

    /// Total number of website rules in force, category keywords included —
    /// what the tab badge counts.
    var websiteRuleCount: Int {
        websites.count + WebsiteCategory.keywords(for: categories).count
    }

    func excludes(_ app: InstalledApp) -> Bool {
        excludesApp(bundleID: app.bundleID)
    }

    func setExcluded(_ excluded: Bool, for app: InstalledApp) {
        if excluded {
            exclude(ExcludedApp(bundleID: app.bundleID, name: app.name))
        } else {
            removeApp(app.bundleID)
        }
    }

    func setExcluded(_ excluded: Bool, for category: WebsiteCategory) {
        if excluded {
            categories.insert(category)
        } else {
            categories.remove(category)
        }
        persist(Array(categories), key: Self.categoriesKey)
        Log.screen.info("exclusions: category \(category.rawValue) \(excluded ? "on" : "off")")
    }

    func exclude(_ app: ExcludedApp) {
        guard !apps.contains(where: { $0.bundleID == app.bundleID }) else { return }
        apps.append(app)
        persistApps()
        Log.screen.info("exclusions: added app \(app.bundleID)")
    }

    func removeApp(_ bundleID: String) {
        apps.removeAll { $0.bundleID == bundleID }
        persistApps()
        Log.screen.info("exclusions: removed app \(bundleID)")
    }

    /// Returns false when the entry is empty or already present.
    @discardableResult
    func excludeWebsite(_ pattern: String) -> Bool {
        let normalized = Self.normalizeWebsite(pattern)
        guard !normalized.isEmpty, !websites.contains(normalized) else { return false }
        websites.append(normalized)
        persistWebsites()
        Log.screen.info("exclusions: added site \(normalized)")
        return true
    }

    func removeWebsite(_ pattern: String) {
        websites.removeAll { $0 == pattern }
        persistWebsites()
        Log.screen.info("exclusions: removed site \(pattern)")
    }

    func excludesApp(bundleID: String) -> Bool {
        rules.excludesApp(bundleID: bundleID)
    }

    /// Window titles are all a browser exposes without descending into the page,
    /// so an excluded site is matched against the title. A user who blocks
    /// `bank.com` is protected when the tab title carries the domain or the
    /// bank's name; a title that mentions neither is a real gap, which is why
    /// app-level exclusion stays the stronger control.
    func excludesWindow(title: String) -> Bool {
        rules.excludesWindow(title: title)
    }

    /// A pattern containing a dot is a domain and matches anywhere in the title
    /// ("bank.com" inside "Statements — bank.com"). A bare word must match on
    /// word boundaries, or a category quietly eats legitimate meetings:
    /// "shop" would otherwise exclude "Workshop — Google Meet".
    nonisolated static func matches(title: String, patterns: [String]) -> Bool {
        let lowered = title.lowercased()
        let words = Set(TextTokens.words(in: lowered))
        return patterns.contains { pattern in
            guard !pattern.isEmpty else { return false }
            if pattern.contains(".") { return lowered.contains(pattern) }
            return words.contains(pattern)
        }
    }

    /// Strips scheme, `www.`, path and case so "https://www.Bank.com/login" and
    /// "bank.com" become the same rule.
    nonisolated static func normalizeWebsite(_ pattern: String) -> String {
        var value = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        if value.hasPrefix("www.") {
            value.removeFirst(4)
        }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[value.startIndex ..< slash])
        }
        return value
    }

    private func persistApps() {
        persist(apps, key: Self.appsKey)
    }

    private func persistWebsites() {
        persist(websites, key: Self.websitesKey)
    }

    private func persist(_ value: some Encodable, key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Immutable snapshot of the blocklist, safe to read off the main actor by the
/// traversal that actually enforces it.
struct ScreenExclusionRules: Equatable {
    let appBundleIDs: [String]
    let websites: [String]

    static let none = ScreenExclusionRules(appBundleIDs: [], websites: [])

    func excludesApp(bundleID: String) -> Bool {
        appBundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    func excludesWindow(title: String) -> Bool {
        ScreenExclusions.matches(title: title, patterns: websites)
    }
}

extension ScreenExclusions {
    var rules: ScreenExclusionRules {
        ScreenExclusionRules(
            appBundleIDs: apps.map(\.bundleID),
            websites: websites + WebsiteCategory.keywords(for: categories)
        )
    }
}
