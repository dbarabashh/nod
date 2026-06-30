import Foundation

/// Client-side, flag-only duplicate detection for action items across meetings.
/// Single-user product with modest data, so this stays deliberately simple: no
/// embeddings, no backend — normalized token-overlap (Jaccard) between items
/// from *different* meetings. It never merges or deletes; it only surfaces a
/// "possible duplicate" hint the user resolves manually (delete one, or dismiss
/// the flag). Conservative by design: a missed near-paraphrase is fine, a
/// false flag is annoying, so the threshold + shared-token floor err toward
/// under-flagging.
enum ActionItemDedup {
    /// Words shorter than this are dropped as low-signal ("to", "a", and most
    /// inflectional noise) before comparing.
    private static let minTokenLength = 3
    /// Common function words that clear `minTokenLength` but carry no task
    /// signal — dropped so two unrelated tasks ("Ask the team" / "Ask the
    /// client") don't score a shared-token match on "the".
    private static let stopwords: Set<String> = [
        "the", "and", "for", "but", "with", "you", "your", "our", "are", "was",
        "were", "this", "that", "from", "into", "per", "via", "out", "off", "its",
        "has", "have", "will", "their", "them", "they"
    ]
    /// Minimum overlapping meaningful tokens for a pair to qualify — guards
    /// against two short tasks scoring high on a single shared word.
    private static let minSharedTokens = 2

    /// Maps each flagged item id to the id of its strongest cross-meeting match.
    /// Both members of a flagged pair appear as keys. `dismissed` holds pair
    /// keys (see `pairKey`) the user marked "not a duplicate" — those are
    /// skipped. Items already flagged keep their highest-similarity partner.
    static func flag(
        _ items: [ActionItem],
        threshold: Double = 0.5,
        dismissed: Set<String> = []
    ) -> [UUID: UUID] {
        let tokenized = items.map { (item: $0, tokens: tokens($0.text)) }
        var best: [UUID: (other: UUID, score: Double)] = [:]

        for i in 0 ..< tokenized.count {
            for j in (i + 1) ..< tokenized.count {
                let a = tokenized[i], b = tokenized[j]
                guard a.item.meetingID != b.item.meetingID else { continue }
                guard !dismissed.contains(pairKey(a.item.id, b.item.id)) else { continue }
                let shared = a.tokens.intersection(b.tokens)
                guard shared.count >= minSharedTokens else { continue }
                let score = jaccard(a.tokens, b.tokens)
                guard score >= threshold else { continue }
                record(&best, id: a.item.id, other: b.item.id, score: score)
                record(&best, id: b.item.id, other: a.item.id, score: score)
            }
        }
        return best.mapValues(\.other)
    }

    /// Stable key for a pair of ids, order-independent — used to persist
    /// dismissed ("not a duplicate") pairs.
    static func pairKey(_ a: UUID, _ b: UUID) -> String {
        let lo = min(a.uuidString, b.uuidString)
        let hi = max(a.uuidString, b.uuidString)
        return "\(lo)|\(hi)"
    }

    static func tokens(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        let parts = lowered.unicodeScalars.split { !CharacterSet.alphanumerics.contains($0) }
        return Set(parts.map(String.init).filter { $0.count >= minTokenLength && !stopwords.contains($0) })
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let inter = a.intersection(b).count
        let union = a.union(b).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }

    private static func record(_ best: inout [UUID: (other: UUID, score: Double)], id: UUID, other: UUID, score: Double) {
        if let existing = best[id], existing.score >= score { return }
        best[id] = (other, score)
    }
}
