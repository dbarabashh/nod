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
    /// Domains captured even when an excluded category matches them. See
    /// `ScreenExclusionRules.excludesWindow` for why it cannot overrule an
    /// explicitly excluded site.
    @Published private(set) var alwaysIncluded: [String] = []

    private let defaults: UserDefaults
    private static let appsKey = "screen.exclusions.apps"
    private static let websitesKey = "screen.exclusions.websites"
    private static let categoriesKey = "screen.exclusions.categories"
    private static let alwaysIncludedKey = "screen.exclusions.alwaysIncluded"
    /// Every website default ever *offered* to this install, on the same
    /// once-only contract as the app list: a default the user deleted must not
    /// reappear, while one added in a later version still reaches them.
    private static let offeredWebsitesKey = "screen.exclusions.offeredWebsites"
    /// Legacy flag: "the messenger defaults have been seeded". Read only, to
    /// migrate an install that predates `offeredMessengersKey`.
    private static let seededMessengersKey = "screen.exclusions.seededMessengers"
    /// Every default that has ever been *offered* to this install, whether or
    /// not it is still excluded. A plain "already seeded" flag couldn't tell a
    /// list that had grown from one that hadn't, so a messenger added to the
    /// defaults later never reached anyone who had already run Nod once.
    private static let offeredMessengersKey = "screen.exclusions.offeredMessengers"

    /// Personal messengers and password managers, excluded before the user has
    /// said anything.
    ///
    /// Ambient capture reads the window you are looking at, and the two windows
    /// people look at most are a private conversation with someone who never
    /// agreed to any of this, and a vault listing every account they own. A
    /// blocklist that starts empty puts both in the index by default and asks
    /// the user to notice afterwards.
    ///
    /// Seeded, not hardcoded: it lands in the same list as any other exclusion,
    /// so a user who *wants* one of these indexed can untick it and it stays off
    /// — see `seedDefaultsIfNeeded`.
    /// Telegram ships under three different identifiers and each one is a
    /// separate entry: matching is by bundle id, so the two that were listed
    /// here left the build most people actually run — `com.tdesktop.Telegram` —
    /// readable by default. An app missing from this list is not a cosmetic gap;
    /// it is private conversation, or a password, in the index.
    static let defaultExcludedApps = [
        ExcludedApp(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp"),
        ExcludedApp(bundleID: "com.tdesktop.Telegram", name: "Telegram"),
        ExcludedApp(bundleID: "ru.keepcoder.Telegram", name: "Telegram"),
        ExcludedApp(bundleID: "org.telegram.desktop", name: "Telegram Desktop"),
        ExcludedApp(bundleID: "com.apple.MobileSMS", name: "Messages"),
        ExcludedApp(bundleID: "com.facebook.archon", name: "Messenger"),
        ExcludedApp(bundleID: "com.signal.Signal", name: "Signal"),
        ExcludedApp(bundleID: "org.whispersystems.signal-desktop", name: "Signal"),
        ExcludedApp(bundleID: "com.viber.osx", name: "Viber"),
        ExcludedApp(bundleID: "com.hnc.Discord", name: "Discord"),
        ExcludedApp(bundleID: "com.1password.1password", name: "1Password"),
        ExcludedApp(bundleID: "com.agilebits.onepassword7", name: "1Password 7"),
        ExcludedApp(bundleID: "com.bitwarden.desktop", name: "Bitwarden"),
        ExcludedApp(bundleID: "com.lastpass.LastPass", name: "LastPass"),
        ExcludedApp(bundleID: "com.dashlane.Dashlane", name: "Dashlane"),
        ExcludedApp(bundleID: "com.callpod.keeper-mac", name: "Keeper"),
        ExcludedApp(bundleID: "com.nordpass.macos", name: "NordPass"),
        ExcludedApp(bundleID: "me.proton.pass.electron", name: "Proton Pass"),
        ExcludedApp(bundleID: "in.sinew.Enpass-Desktop", name: "Enpass"),
        ExcludedApp(bundleID: "com.apple.Passwords", name: "Passwords"),
        ExcludedApp(bundleID: "org.keepassxc.keepassxc", name: "KeePassXC")
    ]

    /// Sites excluded before the user has configured anything: password vaults,
    /// and the one-time-secret services people paste credentials into.
    ///
    /// These are the windows where a single capture is worst — a vault listing
    /// every account name, or a link whose whole purpose is to be read once and
    /// destroyed. A category can't cover them: "banking" doesn't match
    /// `1password.com`, and the title of a vault is usually just the item name.
    ///
    /// Matched by domain against the window title, so this only reaches a site
    /// open in a *browser*. The desktop apps are covered by
    /// `defaultExcludedApps` — both halves are needed, because most people use
    /// the app and some use the web vault.
    static let defaultExcludedWebsites = [
        "1password.com",
        "bitwarden.com",
        "lastpass.com",
        "dashlane.com",
        "keepersecurity.com",
        "nordpass.com",
        "pass.proton.me",
        "enpass.io",
        "roboform.com",
        "pwpush.com",
        "onetimesecret.com",
        "privnote.com",
        "yopass.se",
        "scrt.link",
        "1ty.me"
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
        alwaysIncluded = Self.decode([String].self, from: defaults, key: Self.alwaysIncludedKey) ?? []
        if seedDefaults {
            seedAppDefaultsIfNeeded()
            seedWebsiteDefaultsIfNeeded()
        }
    }

    /// Offers each app default exactly once, ever.
    ///
    /// Once, so an app the user deliberately removed never comes back. Each,
    /// so a default added in a later version still reaches installs that have
    /// already run — which is what a single "seeded" flag got wrong, leaving
    /// every existing install without the Telegram build most people have.
    private func seedAppDefaultsIfNeeded() {
        var offered = Set(defaults.stringArray(forKey: Self.offeredMessengersKey) ?? [])
        if offered.isEmpty, defaults.bool(forKey: Self.seededMessengersKey) {
            offered = Self.firstSeededBundleIDs
        }

        let known = Set(apps.map(\.bundleID))
        let all = Self.defaultExcludedApps.map(\.bundleID)
        let added = Self.defaultExcludedApps.filter {
            !offered.contains($0.bundleID) && !known.contains($0.bundleID)
        }
        // Only when it would change something. In the steady state — every
        // launch after the first — this used to rebuild and rewrite an
        // identical array through `cfprefsd` on the startup path.
        if !offered.isSuperset(of: all) {
            defaults.set(offered.union(all).sorted(), forKey: Self.offeredMessengersKey)
        }

        guard !added.isEmpty else { return }
        apps.append(contentsOf: added)
        persistApps()
        Log.screen.info("exclusions: seeded \(added.count) app default(s)")
    }

    /// The same once-only contract for the website defaults. No legacy flag to
    /// migrate — this list did not exist before, so an install that has never
    /// been offered it gets the whole thing.
    private func seedWebsiteDefaultsIfNeeded() {
        let offered = Set(defaults.stringArray(forKey: Self.offeredWebsitesKey) ?? [])
        let known = Set(websites)
        // A site the user put on the always-include list is an explicit "read
        // this". Seeding it into the blocklist would, by the documented
        // precedence, silently overrule them and leave their own entry sitting
        // in the UI doing nothing.
        let allowed = Set(alwaysIncluded)
        let added = Self.defaultExcludedWebsites.filter {
            !offered.contains($0) && !known.contains($0) && !allowed.contains($0)
        }
        if !offered.isSuperset(of: Self.defaultExcludedWebsites) {
            defaults.set(offered.union(Self.defaultExcludedWebsites).sorted(), forKey: Self.offeredWebsitesKey)
        }

        guard !added.isEmpty else { return }
        websites.append(contentsOf: added)
        persistWebsites()
        Log.screen.info("exclusions: seeded \(added.count) website default(s)")
    }

    /// Whether a site is one Nod shipped rather than one the user typed. Only
    /// the label differs — a default is an ordinary entry and removes the same
    /// way, which is what makes shipping one defensible.
    static func isDefaultWebsite(_ pattern: String) -> Bool {
        defaultExcludedWebsites.contains(pattern)
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

    /// Why an always-include entry was refused. The store knows which rule
    /// rejected it; returning a bare `false` made the view re-derive the
    /// precedence to guess, leaving two copies of it to keep in sync.
    enum AlwaysIncludeRejection: Equatable {
        case empty
        case duplicate
        /// Explicitly excluded, so the entry would silently do nothing — an
        /// exclusion by name always wins.
        case excluded
    }

    /// Adds a site to the always-capture list, or says why not.
    @discardableResult
    func alwaysInclude(_ pattern: String) -> AlwaysIncludeRejection? {
        let normalized = Self.normalizeWebsite(pattern)
        guard !normalized.isEmpty else { return .empty }
        guard !alwaysIncluded.contains(normalized) else { return .duplicate }
        guard !websites.contains(normalized) else { return .excluded }
        alwaysIncluded.append(normalized)
        persist(alwaysIncluded, key: Self.alwaysIncludedKey)
        Log.screen.info("exclusions: always include \(normalized)")
        return nil
    }

    func removeAlwaysIncluded(_ pattern: String) {
        alwaysIncluded.removeAll { $0 == pattern }
        persist(alwaysIncluded, key: Self.alwaysIncludedKey)
        Log.screen.info("exclusions: dropped always-include \(pattern)")
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
    /// Domains the user (or a shipped default) named outright.
    let websites: [String]
    /// The broad keyword lists behind the category switches. Kept apart from
    /// `websites` because only these can be overridden — see `excludesWindow`.
    let categoryKeywords: [String]
    /// Domains to capture even when a category would have excluded them.
    let alwaysIncluded: [String]

    init(
        appBundleIDs: [String],
        websites: [String],
        categoryKeywords: [String] = [],
        alwaysIncluded: [String] = []
    ) {
        self.appBundleIDs = appBundleIDs
        self.websites = websites
        self.categoryKeywords = categoryKeywords
        self.alwaysIncluded = alwaysIncluded
    }

    static let none = ScreenExclusionRules(appBundleIDs: [], websites: [])

    func excludesApp(bundleID: String) -> Bool {
        appBundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// Precedence, and the reason for it: a named exclusion always wins, and the
    /// allowlist can only overrule a *category*.
    ///
    /// Categories are keyword matches against a window title, so they are
    /// deliberately broad and catch things they shouldn't — "shopping" swallows
    /// a supplier portal, "social" swallows a LinkedIn recruiting call. The
    /// allowlist is the escape hatch for exactly that. What it must never do is
    /// re-open a site the user typed into the blocklist themselves: that is an
    /// explicit "never read this", and no other rule gets to overrule it.
    func excludesWindow(title: String) -> Bool {
        if ScreenExclusions.matches(title: title, patterns: websites) { return true }
        if ScreenExclusions.matches(title: title, patterns: alwaysIncluded) { return false }
        return ScreenExclusions.matches(title: title, patterns: categoryKeywords)
    }
}

extension ScreenExclusions {
    var rules: ScreenExclusionRules {
        ScreenExclusionRules(
            appBundleIDs: apps.map(\.bundleID),
            websites: websites,
            categoryKeywords: WebsiteCategory.keywords(for: categories),
            alwaysIncluded: alwaysIncluded
        )
    }
}
