import Foundation

/// Offline reader for Granola's local cache (`cache-v3.json`).
///
/// Granola keeps an on-disk mirror of every meeting — documents and their
/// transcript segments — so it works without a network connection. We read it
/// directly: no Granola API call, no Granola credentials. The file is a JSON
/// matryoshka — an outer `{ "cache": "<stringified JSON>" }` whose string value
/// is itself `{ "state": { "documents": {…}, "transcripts": {…} } }`. Parsing
/// is intentionally tolerant (untyped `JSONSerialization`) so a newer Granola
/// build that adds fields still imports rather than failing to decode.
enum GranolaCache {
    /// macOS location of Granola's offline cache.
    static var defaultCacheURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Granola/cache-v3.json")
    }

    struct Document {
        let id: String
        let title: String
        let createdAt: String
    }

    /// One transcript line. `source` is Granola's own channel tag —
    /// `"microphone"` for the user, anything else for system/remote audio,
    /// which maps cleanly onto Nod's source-based `me` / `them` labels.
    struct Segment {
        let id: String
        let documentID: String
        let startTimestamp: String
        let text: String
        let source: String
    }

    struct Contents {
        let documents: [String: Document]
        /// Transcript segments keyed by document id, kept in cache (chronological) order.
        let transcripts: [String: [Segment]]
    }

    enum ReadError: LocalizedError {
        case fileNotFound(URL)
        case unreadable(Error)
        case malformed

        var errorDescription: String? {
            switch self {
            case .fileNotFound:
                "Granola cache not found. Open Granola at least once, then try again."
            case let .unreadable(error):
                "Couldn't read the Granola cache: \(error.localizedDescription)"
            case .malformed:
                "The Granola cache has an unexpected format — it may be a newer version Nod doesn't support yet."
            }
        }
    }

    static func read(from url: URL = defaultCacheURL) throws -> Contents {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReadError.fileNotFound(url)
        }
        let raw: Data
        do {
            raw = try Data(contentsOf: url)
        } catch {
            throw ReadError.unreadable(error)
        }
        return try parse(raw)
    }

    static func parse(_ raw: Data) throws -> Contents {
        guard
            let outer = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
            let cacheString = outer["cache"] as? String,
            let innerData = cacheString.data(using: .utf8),
            let inner = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any],
            let state = inner["state"] as? [String: Any]
        else {
            throw ReadError.malformed
        }

        var documents: [String: Document] = [:]
        if let docs = state["documents"] as? [String: Any] {
            for (id, value) in docs {
                guard let obj = value as? [String: Any] else { continue }
                let title = (obj["title"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                documents[id] = Document(
                    id: id,
                    title: title,
                    createdAt: obj["created_at"] as? String ?? ""
                )
            }
        }

        var transcripts: [String: [Segment]] = [:]
        if let txs = state["transcripts"] as? [String: Any] {
            for (docID, value) in txs {
                guard let arr = value as? [[String: Any]] else { continue }
                let segments: [Segment] = arr.compactMap { seg in
                    guard
                        let text = (seg["text"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !text.isEmpty
                    else { return nil }
                    return Segment(
                        id: seg["id"] as? String ?? UUID().uuidString,
                        documentID: docID,
                        startTimestamp: seg["start_timestamp"] as? String ?? "",
                        text: text,
                        source: seg["source"] as? String ?? "system"
                    )
                }
                if !segments.isEmpty { transcripts[docID] = segments }
            }
        }

        return Contents(documents: documents, transcripts: transcripts)
    }
}
