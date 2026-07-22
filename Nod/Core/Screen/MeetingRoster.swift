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
}

/// Apps that can be hosting a call. Matching is by bundle identifier: process
/// names are localized and change between releases.
enum ConferencingApp: String, CaseIterable, Equatable {
    case zoom = "us.zoom.xos"
    case teams = "com.microsoft.teams2"
    case webex = "Cisco-Systems.Spark"
    case slack = "com.tinyspeck.slackmacgap"
    case chrome = "com.google.Chrome"
    case safari = "com.apple.Safari"
    case arc = "company.thebrowser.Browser"
    case edge = "com.microsoft.edgemac"

    var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .teams: "Microsoft Teams"
        case .webex: "Webex"
        case .slack: "Slack"
        case .chrome: "Chrome"
        case .safari: "Safari"
        case .arc: "Arc"
        case .edge: "Edge"
        }
    }

    /// A browser is not a meeting — it merely contains one. Its other windows
    /// are the user's private browsing and must never be walked, so a browser
    /// is only ever read through a window whose title names a call.
    var isBrowser: Bool {
        switch self {
        case .chrome, .safari, .arc, .edge: true
        case .zoom, .teams, .webex, .slack: false
        }
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
        guard !names.isEmpty else {
            Log.screen.info("roster: \(app.displayName) running, no participants readable")
            return nil
        }
        Log.screen.info("roster: \(app.displayName) — \(names.count) participant(s)")
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
    /// agree first.
    static func runningConferencingApp(excluding exclusions: ScreenExclusionRules = .none) -> (ConferencingApp, pid_t)? {
        var browser: (ConferencingApp, pid_t)?
        for application in NSWorkspace.shared.runningApplications {
            guard let identifier = application.bundleIdentifier,
                  let known = ConferencingApp(rawValue: identifier),
                  !exclusions.excludesApp(bundleID: identifier)
            else { continue }
            if known.isBrowser {
                browser = browser ?? (known, application.processIdentifier)
            } else {
                return (known, application.processIdentifier)
            }
        }
        return browser
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

    private static let meetLeadingTokens = ["meet – ", "meet - ", "meet — "]

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
