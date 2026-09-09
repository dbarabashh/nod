import Supabase
import XCTest
@testable import Nod

/// `MeetingStore.onTrashChange` is `KnowledgeStore`'s only signal that a
/// cached search result may now point at a trashed (or just-restored)
/// session — see `AppServices.make()`. Exercised through `DemoMode` so the
/// store's demo branch runs (no network call), which is the same path
/// `ScreenPrivacySectionRenderTests` uses to construct a live store type
/// safely in a test.
@MainActor
final class MeetingStoreTrashChangeTests: XCTestCase {
    private func makeStore() -> MeetingStore {
        MeetingStore(supabase: SupabaseClient(supabaseURL: SupabaseConfig.url, supabaseKey: SupabaseConfig.anonKey))
    }

    private func makeMeeting() -> Meeting {
        let now = Date(timeIntervalSince1970: 1_000)
        return Meeting(
            id: UUID(), userID: UUID(), createdAt: nil,
            startedAt: now, endedAt: now.addingTimeInterval(60),
            title: nil, kind: .meeting, summary: "summary", recap: nil,
            language: "en", speakerNames: nil, deletedAt: nil
        )
    }

    override func setUp() {
        super.setUp()
        DemoMode.set(true)
    }

    override func tearDown() {
        DemoMode.set(false)
        super.tearDown()
    }

    func testSoftDeleteFiresOnTrashChange() async throws {
        let store = makeStore()
        var fired = false
        store.onTrashChange.subscribe { fired = true }

        try await store.softDelete(makeMeeting())

        XCTAssertTrue(fired)
    }

    func testRestoreFiresOnTrashChange() async throws {
        let store = makeStore()
        let meeting = makeMeeting()
        try await store.softDelete(meeting)
        var fired = false
        store.onTrashChange.subscribe { fired = true }

        try await store.restore(meeting.id)

        XCTAssertTrue(fired)
    }

    func testEmptyTrashClearsTrashAndFiresOnTrashChange() async throws {
        let store = makeStore()
        await store.refreshTrash()
        let first = makeMeeting()
        let second = makeMeeting()
        try await store.softDelete(first)
        try await store.softDelete(second)
        XCTAssertEqual(store.trashedMeetings.count, 2)
        XCTAssertNotNil(store.pendingUndo)
        var fired = false
        store.onTrashChange.subscribe { fired = true }

        try await store.emptyTrash()

        XCTAssertTrue(fired)
        XCTAssertTrue(store.trashedMeetings.isEmpty)
        XCTAssertNil(store.pendingUndo)
    }

    func testEmptyTrashSparesTheRecordingSession() async throws {
        let store = makeStore()
        await store.refreshTrash()
        let old = makeMeeting()
        let recording = makeMeeting()
        try await store.softDelete(old)
        try await store.softDelete(recording)
        store.setRecordingMeetingID(recording.id)

        try await store.emptyTrash()

        XCTAssertEqual(store.trashedMeetings.map(\.id), [recording.id])
        XCTAssertEqual(store.pendingUndo?.id, recording.id)
    }

    func testHardDeleteFiresOnTrashChange() async throws {
        let store = makeStore()
        let meeting = makeMeeting()
        var fired = false
        store.onTrashChange.subscribe { fired = true }

        try await store.hardDelete(meeting.id)

        XCTAssertTrue(fired)
    }
}
