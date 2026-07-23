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
    private static let seededMessengersKey = "screen.exclusions.seededMessengers"

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
    static let defaultExcludedMessengers = [
        ExcludedApp(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp"),
        ExcludedApp(bundleID: "ru.keepcoder.Telegram", name: "Telegram"),
        ExcludedApp(bundleID: "org.telegram.desktop", name: "Telegram Desktop"),
        ExcludedApp(bundleID: "com.apple.MobileSMS", name: "Messages"),
        ExcludedApp(bundleID: "com.facebook.archon", name: "Messenger"),
        ExcludedApp(bundleID: "com.signal.Signal", name: "Signal"),
        ExcludedApp(bundleID: "com.viber.osx", name: "Viber"),
        ExcludedApp(bundleID: "com.hnc.Discord", name: "Discord")
    ]

    init(defaults: UserDefaults = .standard, seedDefaults: Bool = true) {
        self.defaults = defaults
        apps = Self.decode([ExcludedApp].self, from: defaults, key: Self.appsKey) ?? []
        websites = Self.decode([String].self, from: defaults, key: Self.websitesKey) ?? []
        categories = Set(Self.decode([WebsiteCategory].self, from: defaults, key: Self.categoriesKey) ?? [])
        if seedDefaults { seedDefaultsIfNeeded() }
    }

    /// Adds the messenger defaults exactly once per install. The flag is what
    /// makes the list a *default* rather than a rule: without it, every launch
    /// would re-add an app the user deliberately removed.
    private func seedDefaultsIfNeeded() {
        guard !defaults.bool(forKey: Self.seededMessengersKey) else { return }
        defaults.set(true, forKey: Self.seededMessengersKey)

        let known = Set(apps.map(\.bundleID))
        let added = Self.defaultExcludedMessengers.filter { !known.contains($0.bundleID) }
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
        defaults.set(try? JSONEncoder().encode(Array(categories)), forKey: Self.categoriesKey)
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
        apps.contains { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// Window titles are all a browser exposes without descending into the page,
    /// so an excluded site is matched against the title. A user who blocks
    /// `bank.com` is protected when the tab title carries the domain or the
    /// bank's name; a title that mentions neither is a real gap, which is why
    /// app-level exclusion stays the stronger control.
    func excludesWindow(title: String) -> Bool {
        Self.matches(title: title, patterns: websites + WebsiteCategory.keywords(for: categories))
    }

    /// A pattern containing a dot is a domain and matches anywhere in the title
    /// ("bank.com" inside "Statements — bank.com"). A bare word must match on
    /// word boundaries, or a category quietly eats legitimate meetings:
    /// "shop" would otherwise exclude "Workshop — Google Meet".
    nonisolated static func matches(title: String, patterns: [String]) -> Bool {
        let lowered = title.lowercased()
        let words = Set(lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
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
        defaults.set(try? JSONEncoder().encode(apps), forKey: Self.appsKey)
    }

    private func persistWebsites() {
        defaults.set(try? JSONEncoder().encode(websites), forKey: Self.websitesKey)
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
