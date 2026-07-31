import CryptoKit
import Foundation

/// One capture of what a window was showing, as text.
///
/// Wire-compatible with `screen_observations`. `contentHash` is what collapses
/// a polling capture's near-duplicates: an unchanged window re-observed a
/// hundred times must stay one row, or the store fills with noise and the
/// retrieval it feeds gets worse, not better.
struct ScreenObservation: Codable, Equatable, Identifiable {
    let id: UUID
    let userID: UUID
    let observedAt: Date
    let sourceApp: String
    let sourceTitle: String
    let content: String
    let contentHash: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case observedAt = "observed_at"
        case sourceApp = "source_app"
        case sourceTitle = "source_title"
        case content
        case contentHash = "content_hash"
        case expiresAt = "expires_at"
    }

    init(
        id: UUID = UUID(),
        userID: UUID,
        observedAt: Date = Date(),
        sourceApp: String,
        sourceTitle: String,
        content: String,
        retention: TimeInterval
    ) {
        self.id = id
        self.userID = userID
        self.observedAt = observedAt
        self.sourceApp = sourceApp
        self.sourceTitle = sourceTitle
        self.content = content
        contentHash = Self.hash(content)
        expiresAt = observedAt.addingTimeInterval(retention)
    }

    /// Hash of the *normalised* text, so a re-render that only shuffles
    /// whitespace — which a UI does constantly — is recognised as unchanged.
    static func hash(_ content: String) -> String {
        let normalized = content
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The metadata half of an observation — everything the activity fold needs
/// except the text itself.
///
/// A recap has to see the whole window it was asked about, and the bodies are
/// what make that expensive: up to 4000 characters a row, nearly all of them
/// folded away unread. Reading the index first decides which windows matter for
/// a fraction of the payload, so the row budget is spent on coverage instead of
/// on text nobody sees.
struct ScreenObservationIndex: Decodable, Equatable {
    let observedAt: Date
    let sourceApp: String
    let sourceTitle: String
    let contentHash: String

    enum CodingKeys: String, CodingKey {
        case observedAt = "observed_at"
        case sourceApp = "source_app"
        case sourceTitle = "source_title"
        case contentHash = "content_hash"
    }

    static let columns = "observed_at,source_app,source_title,content_hash"
}

/// Turns the strings an accessibility walk returns into something worth
/// storing, or into nothing at all.
enum ScreenObservationBuilder {
    /// Below this, a window carries no answerable content — a toolbar, an empty
    /// panel, a loading state. Storing it costs retrieval quality.
    static let minimumCharacters = 120

    /// Below this, accessibility technically returned *something* but not
    /// enough to answer from, and the window is worth reading off the pixels
    /// instead.
    ///
    /// Separate from `minimumCharacters` on purpose: 120 answers "is there
    /// anything here at all", which a Slack channel clears with 122 characters
    /// of its own sidebar while carrying none of the conversation. Gating the
    /// OCR fallback on that number meant it could only fire when accessibility
    /// returned nothing — never in the case it was written for.
    static let thinCharacters = 600
    /// Above this, we are storing a document, not a glance. Truncation keeps a
    /// single row from dominating retrieval.
    static let maximumCharacters = 4_000

    /// Puts the window title at the head of the stored text, so a title-only
    /// match is findable. Skipped when the body already starts with it — many
    /// windows repeat their own title as the first label.
    static func merge(title: String, text: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !text.hasPrefix(trimmed) else { return text }
        return trimmed + "\n" + text
    }

    /// Joins, collapses, and trims a walk's output. Returns nil when the window
    /// has nothing worth keeping.
    /// Repeats are collapsed only where they are adjacent. A line that comes
    /// back later in a window is structure, not noise: in a chat thread it is
    /// the same person posting again, and dropping the second occurrence left
    /// their message with no author line above it. An answer then read the
    /// nearest name — an `@mention` inside the message — as the sender, and
    /// reported a reply from someone who had not written since yesterday.
    static func text(from parts: [String]) -> String? {
        var lines: [String] = []
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != lines.last else { continue }
            lines.append(trimmed)
        }

        let joined = lines.joined(separator: "\n")
        guard informativeLength(of: joined) >= minimumCharacters else { return nil }
        guard joined.count > maximumCharacters else { return joined }
        return String(joined.prefix(maximumCharacters))
    }

    /// Characters of *distinct* content — what a window says, ignoring what it
    /// repeats.
    ///
    /// Both thresholds were calibrated when repeated lines were dropped
    /// outright. Keeping them (so a chat thread keeps its bylines) inflates raw
    /// length, and raw length is what decides whether a window is worth storing
    /// and whether it is thin enough to re-read off the pixels. A sidebar label
    /// repeated forty times would clear both bars while carrying one line of
    /// content — suppressing the pixel read in exactly the case it exists for.
    static func informativeLength(of text: String) -> Int {
        var seen = Set<Substring>()
        return text
            .split(separator: "\n")
            .filter { seen.insert($0).inserted }
            .reduce(0) { $0 + $1.count + 1 }
    }
}
