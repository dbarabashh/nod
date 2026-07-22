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

/// Turns the strings an accessibility walk returns into something worth
/// storing, or into nothing at all.
enum ScreenObservationBuilder {
    /// Below this, a window carries no answerable content — a toolbar, an empty
    /// panel, a loading state. Storing it costs retrieval quality.
    static let minimumCharacters = 120
    /// Above this, we are storing a document, not a glance. Truncation keeps a
    /// single row from dominating retrieval.
    static let maximumCharacters = 4_000

    /// Joins, collapses, and trims a walk's output. Returns nil when the window
    /// has nothing worth keeping.
    static func text(from parts: [String]) -> String? {
        var seen = Set<String>()
        let lines = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }

        let joined = lines.joined(separator: "\n")
        guard joined.count >= minimumCharacters else { return nil }
        guard joined.count > maximumCharacters else { return joined }
        return String(joined.prefix(maximumCharacters))
    }
}
