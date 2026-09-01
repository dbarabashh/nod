import XCTest
@testable import Nod

/// Records what the outbox pushed and can simulate transient failures, so the
/// WAL state machine is tested without a live Supabase.
final class FakeRemoteWriter: MeetingRemoteWriter, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var upsertedMeetings: [Meeting] = []
    private(set) var upsertedTranscripts: [TranscriptRecord] = []
    var failMeetingUpsert = false

    enum Failure: Error { case forced }

    func upsert(_ meeting: Meeting) async throws {
        if failMeetingUpsert { throw Failure.forced }
        lock.lock(); defer { lock.unlock() }
        upsertedMeetings.append(meeting)
    }

    func upsertTranscript(_ records: [TranscriptRecord]) async throws {
        lock.lock(); defer { lock.unlock() }
        upsertedTranscripts.append(contentsOf: records)
    }

    var uniqueTranscriptIDs: Set<UUID> {
        Set(upsertedTranscripts.map(\.id))
    }
}

final class MeetingOutboxTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixtures

    private func makeMeeting(id: UUID = UUID(), userID: UUID, summary: String = "") -> Meeting {
        Meeting(
            id: id,
            userID: userID,
            createdAt: nil,
            startedAt: Date(timeIntervalSince1970: 1000),
            endedAt: Date(timeIntervalSince1970: 2000),
            title: nil,
            kind: .meeting,
            summary: summary,
            recap: nil,
            language: "en",
            speakerNames: nil,
            deletedAt: nil
        )
    }

    private func makeRecord(
        _ idx: Int,
        meetingID: UUID,
        userID: UUID,
        speaker: Int? = nil,
        at ts: Date? = nil
    ) -> TranscriptRecord {
        TranscriptRecord(
            id: UUID(),
            meetingID: meetingID,
            userID: userID,
            createdAt: nil,
            source: "them",
            text: "line \(idx)",
            ts: ts ?? Date(timeIntervalSince1970: Double(idx)),
            idx: idx,
            speaker: speaker
        )
    }

    // MARK: - Core flush

    func testCompletedMeetingPushesAndDrains() async {
        let user = UUID()
        let outbox = MeetingOutbox(directory: tempDir)
        let writer = FakeRemoteWriter()
        let meeting = makeMeeting(userID: user, summary: "recap")
        let records = [
            makeRecord(0, meetingID: meeting.id, userID: user),
            makeRecord(1, meetingID: meeting.id, userID: user)
        ]

        await outbox.begin(makeMeeting(id: meeting.id, userID: user))
        await outbox.record(records, for: meeting.id)
        await outbox.complete(meeting, transcripts: records, for: meeting.id)
        await outbox.flush(using: writer, userID: user)

        XCTAssertEqual(writer.upsertedMeetings.last?.summary, "recap")
        XCTAssertEqual(writer.uniqueTranscriptIDs, Set(records.map(\.id)))
        let pending = await outbox.isPending(meeting.id)
        XCTAssertFalse(pending, "fully-synced completed entry must be removed")
    }

    /// Diarization only resolves at End, so a row streamed mid-recording is
    /// already marked synced by the time it gains a speaker. Without re-sending
    /// it the labels never leave the Mac — and every meeting long enough to
    /// stream is affected, which is nearly all of them.
    func testStreamedRowsAreRePushedOnceDiarizationLabelsThem() async {
        let user = UUID()
        let outbox = MeetingOutbox(directory: tempDir)
        let writer = FakeRemoteWriter()
        let meeting = makeMeeting(userID: user, summary: "recap")
        let streamed = [
            makeRecord(0, meetingID: meeting.id, userID: user),
            makeRecord(1, meetingID: meeting.id, userID: user)
        ]

        await outbox.begin(makeMeeting(id: meeting.id, userID: user))
        await outbox.record(streamed, for: meeting.id)
        await outbox.flush(using: writer, userID: user)
        XCTAssertTrue(writer.upsertedTranscripts.allSatisfy { $0.speaker == nil })

        // Same rows, same ids — this is the finalize snapshot, not new lines.
        let labelled = streamed.enumerated().map { offset, record in
            TranscriptRecord(
                id: record.id,
                meetingID: record.meetingID,
                userID: record.userID,
                createdAt: record.createdAt,
                source: record.source,
                text: record.text,
                ts: record.ts,
                idx: record.idx,
                speaker: offset + 1
            )
        }
        await outbox.complete(meeting, transcripts: labelled, for: meeting.id)
        await outbox.flush(using: writer, userID: user)

        let final = Dictionary(
            writer.upsertedTranscripts.map { ($0.idx, $0.speaker) },
            uniquingKeysWith: { _, latest in latest }
        )
        XCTAssertEqual(final[0], 1)
        XCTAssertEqual(final[1], 2)
    }

    func testEmptyRecordingProducesNoServerRow() async {
        let user = UUID()
        let outbox = MeetingOutbox(directory: tempDir)
        let writer = FakeRemoteWriter()
        let meeting = makeMeeting(userID: user)

        await outbox.begin(meeting)
        await outbox.flush(using: writer, userID: user)

        XCTAssertTrue(writer.upsertedMeetings.isEmpty, "an empty in-progress recording must not create a server row")
    }

    // MARK: - User scoping (cross-user replay guard)

    func testFlushIsScopedToUser() async {
        let userA = UUID()
        let userB = UUID()
        let outbox = MeetingOutbox(directory: tempDir)
        let writer = FakeRemoteWriter()

        let a = makeMeeting(userID: userA, summary: "A")
        let b = makeMeeting(userID: userB, summary: "B")
        let aRecs = [makeRecord(0, meetingID: a.id, userID: userA)]
        let bRecs = [makeRecord(0, meetingID: b.id, userID: userB)]
        await outbox.complete(a, transcripts: aRecs, for: a.id)
        await outbox.complete(b, transcripts: bRecs, for: b.id)

        await outbox.flush(using: writer, userID: userA)

        XCTAssertEqual(writer.upsertedMeetings.map(\.id), [a.id], "only the current user's row may be pushed")
        let bPending = await outbox.isPending(b.id)
        XCTAssertTrue(bPending, "the other user's row stays on disk for when they sign back in")
    }

    // MARK: - Failure / retry durability

    func testFailedFlushKeepsEntryThenSucceedsOnRetry() async {
        let user = UUID()
        let outbox = MeetingOutbox(directory: tempDir)
        let writer = FakeRemoteWriter()
        writer.failMeetingUpsert = true

        let meeting = makeMeeting(userID: user, summary: "recap")
        let records = [makeRecord(0, meetingID: meeting.id, userID: user)]
        await outbox.complete(meeting, transcripts: records, for: meeting.id)

        await outbox.flush(using: writer, userID: user)
        var pending = await outbox.isPending(meeting.id)
        XCTAssertTrue(pending, "a failed push must keep the entry for retry")

        writer.failMeetingUpsert = false
        await outbox.flush(using: writer, userID: user)
        pending = await outbox.isPending(meeting.id)
        XCTAssertFalse(pending, "retry after recovery must drain the entry")
        XCTAssertEqual(writer.uniqueTranscriptIDs, Set(records.map(\.id)))
    }

    func testStreamThenCompleteDoesNotDuplicateTranscripts() async {
        let user = UUID()
        let outbox = MeetingOutbox(directory: tempDir)
        let writer = FakeRemoteWriter()
        let meeting = makeMeeting(userID: user, summary: "recap")
        let r0 = makeRecord(0, meetingID: meeting.id, userID: user)
        let r1 = makeRecord(1, meetingID: meeting.id, userID: user)
        let r2 = makeRecord(2, meetingID: meeting.id, userID: user)

        // Live streaming pushes a prefix...
        await outbox.begin(makeMeeting(id: meeting.id, userID: user))
        await outbox.record([r0, r1], for: meeting.id)
        await outbox.flush(using: writer, userID: user)
        // ...then End completes with the full snapshot.
        await outbox.complete(meeting, transcripts: [r0, r1, r2], for: meeting.id)
        await outbox.flush(using: writer, userID: user)

        XCTAssertEqual(writer.uniqueTranscriptIDs, Set([r0, r1, r2].map(\.id)))
        XCTAssertEqual(writer.upsertedTranscripts.count, 3, "each record must be pushed exactly once")
        XCTAssertEqual(writer.upsertedMeetings.last?.summary, "recap")
    }

    // MARK: - Persistence round-trip (crash / quit / app-update recovery)

    func testCompletedEntrySurvivesReload() async {
        let user = UUID()
        let meeting = makeMeeting(userID: user, summary: "recap")
        let records = [
            makeRecord(0, meetingID: meeting.id, userID: user),
            makeRecord(1, meetingID: meeting.id, userID: user)
        ]

        // First "process": stamp it, never flush (simulate quit before sync).
        let first = MeetingOutbox(directory: tempDir)
        await first.complete(meeting, transcripts: records, for: meeting.id)

        // Second "process": a fresh outbox on the same dir reloads and pushes.
        let second = MeetingOutbox(directory: tempDir)
        let writer = FakeRemoteWriter()
        await second.flush(using: writer, userID: user)

        XCTAssertEqual(writer.upsertedMeetings.map(\.id), [meeting.id])
        XCTAssertEqual(writer.upsertedMeetings.last?.summary, "recap")
        XCTAssertEqual(writer.uniqueTranscriptIDs, Set(records.map(\.id)))
    }

    // MARK: - Interrupted-meeting recovery

    func testRecoverPromotesInterruptedRecordingToPlaceholder() async {
        let user = UUID()
        let meeting = makeMeeting(userID: user)
        let records = [makeRecord(0, meetingID: meeting.id, userID: user)]

        // First "process": begin + stream, but crash before End (stays .recording).
        let first = MeetingOutbox(directory: tempDir)
        await first.begin(meeting)
        await first.record(records, for: meeting.id)

        // Second "process": recover at launch, then flush.
        let second = MeetingOutbox(directory: tempDir)
        let writer = FakeRemoteWriter()
        await second.recoverInterruptedMeetings()
        await second.flush(using: writer, userID: user)

        XCTAssertEqual(writer.upsertedMeetings.map(\.id), [meeting.id])
        XCTAssertEqual(writer.upsertedMeetings.last?.summary, Meeting.recoveredPlaceholder)
        XCTAssertEqual(writer.uniqueTranscriptIDs, Set(records.map(\.id)), "the interrupted transcript is preserved")
        let pending = await second.isPending(meeting.id)
        XCTAssertFalse(pending, "a recovered meeting reaches a terminal, drainable state")
    }

    /// The draft on disk is written with `endedAt` seeded to `startedAt`, and the
    /// real end is stamped at End — the step an interrupted recording never
    /// reaches. Recovering it without fixing that files an hour of conversation
    /// as a meeting of zero length.
    func testRecoveredMeetingEndsWhenTheTalkingStopped() async {
        let user = UUID()
        var draft = makeMeeting(userID: user)
        draft.endedAt = draft.startedAt // exactly what `beginRecording` writes

        let lastHeard = draft.startedAt.addingTimeInterval(3600)
        let records = [
            makeRecord(0, meetingID: draft.id, userID: user, at: draft.startedAt.addingTimeInterval(5)),
            makeRecord(1, meetingID: draft.id, userID: user, at: lastHeard)
        ]

        let first = MeetingOutbox(directory: tempDir)
        await first.begin(draft)
        await first.record(records, for: draft.id)

        let second = MeetingOutbox(directory: tempDir)
        let writer = FakeRemoteWriter()
        await second.recoverInterruptedMeetings()
        await second.flush(using: writer, userID: user)

        XCTAssertEqual(writer.upsertedMeetings.last?.endedAt, lastHeard)
        XCTAssertEqual(writer.upsertedMeetings.last?.startedAt, draft.startedAt, "the start is not moved")
    }

    func testRecoverDropsEmptyInterruptedRecording() async {
        let user = UUID()
        let meeting = makeMeeting(userID: user)

        let first = MeetingOutbox(directory: tempDir)
        await first.begin(meeting) // begun, nothing ever captured

        let second = MeetingOutbox(directory: tempDir)
        let writer = FakeRemoteWriter()
        await second.recoverInterruptedMeetings()
        await second.flush(using: writer, userID: user)

        XCTAssertTrue(writer.upsertedMeetings.isEmpty, "an empty interrupted recording is dropped, not persisted")
        let pending = await second.isPending(meeting.id)
        XCTAssertFalse(pending)
    }

    func testInProgressRecordingNotRecoveredWhenBegunThisSession() async {
        // An entry begun in THIS process (not loaded from disk at launch) must
        // never be promoted by recover — guards the sign-in vs beginRecording race.
        let user = UUID()
        let outbox = MeetingOutbox(directory: tempDir)
        let meeting = makeMeeting(userID: user)
        await outbox.begin(meeting)
        await outbox.record([makeRecord(0, meetingID: meeting.id, userID: user)], for: meeting.id)

        await outbox.recoverInterruptedMeetings()

        let writer = FakeRemoteWriter()
        await outbox.flush(using: writer, userID: user)
        // Still .recording → flush pushes the row + transcript (streaming), but
        // the summary must NOT be the recovery placeholder.
        XCTAssertNotEqual(writer.upsertedMeetings.last?.summary, Meeting.recoveredPlaceholder)
    }
}
