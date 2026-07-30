import AppKit
import Foundation
import os

/// The people a conferencing app says are on the call, read from its
/// accessibility tree while a meeting records.
///
/// Two things come out of a roster, and the second matters more: the names, and
/// the *count*. Clustering with a known speaker count is markedly more accurate
/// than clustering against a distance threshold, and the threshold's optimum
/// moves with recording length (see `SpeakerDiarizer.Configuration`), so a
/// roster is the difference between guessing and knowing.
struct MeetingRoster: Equatable {
    let app: ConferencingApp
    let participants: [String]

    var speakerCount: Int {
        participants.count
    }

    /// Folds a later sample of the same call into this one.
    ///
    /// A union, not a replacement, because the number the clustering pass needs
    /// is how many distinct voices the *recording* holds — everyone who was ever
    /// on the call. Someone who joins late is missing from an early sample, and
    /// someone who drops off early is missing from a late one while their voice
    /// is still in the audio. Taking the newest snapshot loses one of those two
    /// every time.
    ///
    /// A different app means a different call, so it replaces rather than merges
    /// — the earlier names belong to something else.
    func merging(_ later: MeetingRoster) -> MeetingRoster {
        guard later.app == app else { return later }
        var seen = Set(participants.map { $0.lowercased() })
        let added = later.participants.filter { seen.insert($0.lowercased()).inserted }
        guard !added.isEmpty else { return self }
        return MeetingRoster(app: app, participants: participants + added)
    }
}

/// Apps that can be hosting a call. Matching is by bundle identifier: process
/// names are localized and change between releases.
enum ConferencingApp: String, CaseIterable, Equatable {
    case zoom = "us.zoom.xos"
    case teams = "com.microsoft.teams2"
    case teamsClassic = "com.microsoft.teams"
    case webex = "Cisco-Systems.Spark"
    case slack = "com.tinyspeck.slackmacgap"
    case discord = "com.hnc.Discord"
    case chrome = "com.google.Chrome"
    case safari = "com.apple.Safari"
    case arc = "company.thebrowser.Browser"
    case edge = "com.microsoft.edgemac"
    case firefox = "org.mozilla.firefox"
    case brave = "com.brave.Browser"

    var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .teams, .teamsClassic: "Microsoft Teams"
        case .webex: "Webex"
        case .slack: "Slack"
        case .discord: "Discord"
        case .chrome: "Chrome"
        case .safari: "Safari"
        case .arc: "Arc"
        case .edge: "Edge"
        case .firefox: "Firefox"
        case .brave: "Brave"
        }
    }

    /// A browser is not a meeting — it merely contains one. Its other windows
    /// are the user's private browsing and must never be walked, so a browser
    /// is only ever read through a window whose title names a call.
    var isBrowser: Bool {
        switch self {
        case .chrome, .safari, .arc, .edge, .firefox, .brave: true
        case .zoom, .teams, .teamsClassic, .webex, .slack, .discord: false
        }
    }

    /// Bundle identifiers of helper processes that exist *only* while a call is
    /// up, mapped back to the app that owns them.
    ///
    /// Zoom is the case worth special-casing: the main app sits in the menu bar
    /// all day, while `CptHost` is spawned for the meeting window and dies when
    /// the meeting does. It costs no permission at all — a process list, not a
    /// window read — and it is the one signal that survives a user who joined
    /// muted with the meeting window behind something else.
    static func owner(ofCallHelper bundleID: String) -> ConferencingApp? {
        bundleID == "us.zoom.CptHost" ? .zoom : nil
    }

    /// Whether this app's windows may be walked for a participant list.
    ///
    /// Not the same question as "can it host a call", and the two must not share
    /// an answer: Discord hosts calls, but a non-browser app is walked *whole*
    /// (there is no title to narrow it to the call), and Discord's windows are
    /// DMs and server channels. Reading them harvests person-shaped strings from
    /// private conversation and feeds them to the recap as participants.
    var exposesParticipantList: Bool {
        self != .discord
    }

    /// Every conferencing app running now, native before browser — a native app
    /// *is* the call, while a browser merely contains one — together with the
    /// apps a meeting-only helper process places in a call.
    ///
    /// Shared because both readers ask the same question of the same process
    /// list and must apply the blocklist the same way; two copies drifted within
    /// a day of the second one existing.
    static func running(excluding rules: ScreenExclusionRules = .none) -> (apps: [(ConferencingApp, pid_t)], inCall: Set<ConferencingApp>) {
        var byApp: [ConferencingApp: pid_t] = [:]
        var inCall: Set<ConferencingApp> = []
        for application in NSWorkspace.shared.runningApplications {
            guard let bundleID = application.bundleIdentifier else { continue }
            if let owner = owner(ofCallHelper: bundleID) { inCall.insert(owner) }
            guard let app = ConferencingApp(rawValue: bundleID),
                  !rules.excludesApp(bundleID: bundleID),
                  byApp[app] == nil
            else { continue }
            byApp[app] = application.processIdentifier
        }
        let ordered = allCases.filter { byApp[$0] != nil }
        let apps = (ordered.filter { !$0.isBrowser } + ordered.filter(\.isBrowser))
            .compactMap { app in byApp[app].map { (app, $0) } }
        return (apps, inCall.intersection(byApp.keys))
    }
}

/// Samples the roster of whichever conferencing app is running.
///
/// Sampling, not streaming: a participant list changes a handful of times per
/// call, so there is nothing to gain from a tight polling loop and a real cost
/// to paying for one. Nothing read here is persisted — the names go to
/// diarization and are dropped with the session.
struct MeetingRosterReader {
    private let reader: AccessibilityReader
    /// The user's blocklist, enforced before any traversal starts.
    private let exclusions: ScreenExclusionRules

    init(reader: AccessibilityReader = AccessibilityReader(), exclusions: ScreenExclusionRules = .none) {
        self.reader = reader
        self.exclusions = exclusions
    }

    /// Blocking — call it off the main actor.
    func sample() -> MeetingRoster? {
        guard let (app, pid) = Self.runningConferencingApp(excluding: exclusions) else { return nil }
        guard AccessibilityAccess.isTrusted else {
            requestTrustOnce(for: app)
            return nil
        }

        let exclusions = exclusions
        let texts = reader.texts(forProcessID: pid) { title in
            guard !exclusions.excludesWindow(title: title) else { return false }
            return app.isBrowser ? Self.isMeetingWindowTitle(title) : true
        }
        let names = Self.participantNames(in: texts)
        // Per-sample, so `.debug`: sampling repeats for the whole call, and the
        // event worth an `.info` line is the accumulated count changing, which
        // the caller logs.
        guard !names.isEmpty else {
            Log.screen.debug("roster: \(app.displayName) running, no participants readable")
            return nil
        }
        Log.screen.debug("roster: \(app.displayName) — \(names.count) participant(s) this sample")
        return MeetingRoster(app: app, participants: names)
    }

    /// Prompt once per launch, and only when a conferencing app is actually
    /// running — an Accessibility request out of nowhere reads as spyware, and
    /// macOS shows it at most once per app version anyway.
    private func requestTrustOnce(for app: ConferencingApp) {
        let alreadyAsked = Self.trustRequested.withLock { asked -> Bool in
            defer { asked = true }
            return asked
        }
        guard !alreadyAsked else { return }
        Log.screen.info("roster: \(app.displayName) running, requesting accessibility access")
        AccessibilityAccess.requestTrust()
    }

    private static let trustRequested = OSAllocatedUnfairLock(initialState: false)

    /// Prefers a native conferencing app over a browser: if Zoom is running, its
    /// window is unambiguously the call, while a browser needs the title to
    /// agree first. Apps whose windows aren't a roster are skipped — see
    /// `exposesParticipantList`.
    static func runningConferencingApp(excluding exclusions: ScreenExclusionRules = .none) -> (ConferencingApp, pid_t)? {
        ConferencingApp.running(excluding: exclusions).apps
            .first { $0.0.exposesParticipantList }
    }

    /// Whether a browser window title names a video call.
    ///
    /// Deliberately narrow: this predicate is the only thing standing between
    /// the reader and the user's other tabs, so an unrecognised title means we
    /// read nothing rather than read too much.
    static func isMeetingWindowTitle(_ title: String) -> Bool {
        let lowered = title.lowercased()
        if meetingWindowMarkers.contains(where: { lowered.contains($0) }) { return true }
        // Google Meet's tab title is bare — "Meet – abc-defg-hij" — so the word
        // has to be matched as a leading token. Prefix-only, or "meeting notes"
        // and every other document with "meet" in it would open the window up.
        return meetLeadingTokens.contains { lowered.hasPrefix($0) }
    }

    private static let meetingWindowMarkers = [
        "google meet",
        "meet.google.com",
        "zoom meeting",
        "microsoft teams",
        "teams.microsoft.com",
        "webex",
        "whereby",
        "jitsi meet"
    ]

    /// Google Meet's bare tab title, in the three dash variants it ships with.
    /// Shared with `MeetingDetection.namesActiveCall`: the two predicates ask
    /// different questions — may this window be read, versus is a call live —
    /// but they recognise Meet by the same three strings, and a fourth added to
    /// one copy and not the other would fail silently in whichever it missed.
    static let meetLeadingTokens = ["meet – ", "meet - ", "meet — "]

    /// Person-shaped strings from a window's text, deduplicated, order kept.
    ///
    /// Conferencing UIs annotate rows ("Dima Barabash (Host, me)"), so the
    /// parenthetical is stripped before matching. Everything else is a
    /// conservative shape test — a wrong name is worse than no name, so a
    /// candidate that isn't obviously a person is dropped rather than guessed.
    static func participantNames(in texts: [String]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for text in texts {
            let candidate = stripAnnotations(text)
            guard isPersonName(candidate), seen.insert(candidate.lowercased()).inserted else { continue }
            names.append(candidate)
        }
        return names
    }

    static func stripAnnotations(_ text: String) -> String {
        let withoutParenthetical = text.prefix(while: { $0 != "(" })
        return withoutParenthetical.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isPersonName(_ candidate: String) -> Bool {
        guard candidate.count >= 2, candidate.count <= 48 else { return false }
        guard !controlLabels.contains(candidate.lowercased()) else { return false }
        guard candidate.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        // Punctuation on its own clears the per-word shape test below — that test
        // admits a word starting with a non-letter, and `.`, `'` and `-` are all
        // allowed characters, so "..", "--" and "''" every one of them read as a
        // name. Conferencing trees are full of separator and ellipsis labels, and
        // each one that gets through becomes a phantom participant, inflating the
        // speaker count handed to clustering.
        guard candidate.contains(where: \.isLetter) else { return false }

        let words = candidate.split(separator: " ")
        guard (1 ... 4).contains(words.count) else { return false }

        return words.allSatisfy { word in
            guard let first = word.first, first.isUppercase || !first.isLetter else { return false }
            return word.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" || $0 == "." }
        }
    }

    /// Buttons and headings that pass the shape test but name no one. Lowercase.
    private static let controlLabels: Set<String> = [
        "mute", "unmute", "participants", "participant", "chat", "share",
        "share screen", "leave", "leave meeting", "end", "end meeting", "record",
        "reactions", "apps", "more", "view", "invite", "close", "search",
        "camera", "video", "start video", "stop video", "raise hand", "host",
        "co-host", "me", "everyone", "meeting", "settings", "waiting room"
    ]
}
