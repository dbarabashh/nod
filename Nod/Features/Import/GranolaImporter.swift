import Combine
import CryptoKit
import Foundation

/// Imports past meetings' transcripts from Granola's offline cache into Nod.
///
/// Transcripts only — fully offline, no Granola account or network. Granola's
/// rich notes live behind its private cloud API and are out of scope here; this
/// path reads `cache-v3.json` and reconstructs each meeting's dialogue.
///
/// Every imported row gets a deterministic UUIDv5 derived from its Granola id,
/// so re-importing upserts the same rows instead of duplicating, and the
/// namespaced ids can never collide with Nod's own random-v4 meeting ids.
@MainActor
final class GranolaImporter: ObservableObject {
    enum State: Equatable {
        case idle
        case importing
        case done(imported: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let meetingStore: MeetingStore
    private let auth: AuthService
    private let language: LanguagePreference

    init(meetingStore: MeetingStore, auth: AuthService, language: LanguagePreference) {
        self.meetingStore = meetingStore
        self.auth = auth
        self.language = language
    }

    /// True when Granola's cache exists on disk — gates the UI so the import
    /// affordance only appears for users who actually have Granola installed.
    var isGranolaInstalled: Bool {
        FileManager.default.fileExists(atPath: GranolaCache.defaultCacheURL.path)
    }

    func importFromCache(url: URL = GranolaCache.defaultCacheURL) async {
        guard let userID = auth.currentSupabaseSession?.user.id else {
            state = .failed("Sign in to Nod before importing.")
            return
        }

        state = .importing
        Log.ui.info("GranolaImporter: reading \(url.path)")
        do {
            let contents = try GranolaCache.read(from: url)
            var imported = 0
            for (docID, segments) in contents.transcripts {
                let doc = contents.documents[docID]
                let meeting = Self.makeMeeting(
                    docID: docID,
                    doc: doc,
                    segments: segments,
                    userID: userID,
                    language: language.current.rawValue
                )
                let records = Self.makeRecords(
                    segments: segments,
                    meeting: meeting,
                    userID: userID
                )
                try await meetingStore.upsert(meeting)
                try await meetingStore.upsertTranscript(records)
                imported += 1
            }
            await meetingStore.refresh(force: true)
            Log.ui.info("GranolaImporter: imported \(imported) meetings")
            state = .done(imported: imported)
        } catch {
            Log.ui.error("GranolaImporter failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Mapping

    private static func makeMeeting(
        docID: String,
        doc: GranolaCache.Document?,
        segments: [GranolaCache.Segment],
        userID: UUID,
        language: String
    ) -> Meeting {
        let startedAt = parseDate(doc?.createdAt ?? "")
            ?? segments.lazy.compactMap { parseDate($0.startTimestamp) }.first
            ?? Date(timeIntervalSince1970: 0)
        let endedAt = segments.reversed().lazy
            .compactMap { parseDate($0.startTimestamp) }
            .first
            .map { max($0, startedAt) } ?? startedAt
        let title = doc?.title.isEmpty == false ? doc?.title : nil

        return Meeting(
            id: deterministicUUID("granola.meeting:" + docID),
            userID: userID,
            createdAt: nil,
            startedAt: startedAt,
            endedAt: endedAt,
            title: title,
            kind: .meeting,
            summary: "",
            recap: nil,
            language: language,
            deletedAt: nil
        )
    }

    private static func makeRecords(
        segments: [GranolaCache.Segment],
        meeting: Meeting,
        userID: UUID
    ) -> [TranscriptRecord] {
        segments.enumerated().map { idx, seg in
            let source: TranscriptSource = seg.source == "microphone" ? .me : .them
            return TranscriptRecord(
                id: deterministicUUID("granola.segment:" + seg.id),
                meetingID: meeting.id,
                userID: userID,
                createdAt: nil,
                source: source.rawValue,
                text: seg.text,
                ts: parseDate(seg.startTimestamp) ?? meeting.startedAt,
                idx: idx,
                speaker: nil
            )
        }
    }

    // MARK: - Helpers

    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated static func parseDate(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        return isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }

    /// 16 ASCII bytes — a fixed namespace so the derived ids are stable across
    /// runs and machines without needing a force-unwrapped `UUID(uuidString:)`.
    private nonisolated static let namespace = Array("NODGRANOLAIMPORT".utf8)

    /// RFC-4122 v5 (SHA-1) UUID — same scheme anarlog uses for imported ids.
    nonisolated static func deterministicUUID(_ name: String) -> UUID {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data(namespace))
        hasher.update(data: Data(name.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress) as UUID }
    }
}
