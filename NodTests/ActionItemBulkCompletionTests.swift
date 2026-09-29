import Supabase
import XCTest
@testable import Nod

@MainActor
final class ActionItemBulkCompletionTests: XCTestCase {
    private var wasDemoEnabled = false

    override func setUp() {
        super.setUp()
        wasDemoEnabled = DemoMode.isEnabled
        DemoMode.set(true)
    }

    override func tearDown() {
        DemoMode.set(wasDemoEnabled)
        super.tearDown()
    }

    private func store() throws -> ActionItemStore {
        try ActionItemStore(supabase: SupabaseClient(
            supabaseURL: XCTUnwrap(URL(string: "http://127.0.0.1:9")), supabaseKey: "local-test"
        ))
    }

    func testOnlyConfirmedSnapshotIsCompleted() async throws {
        let store = try store()
        await store.refresh()
        let open = store.items.filter(\.isOpen)
        XCTAssertGreaterThan(open.count, 2)
        let confirmed = Array(open.prefix(2))
        await store.completeAll(confirmed)
        for item in store.items where open.contains(where: { $0.id == item.id }) {
            XCTAssertEqual(item.done, confirmed.contains { $0.id == item.id })
        }
        XCTAssertFalse(store.isCompletingAll)
        XCTAssertEqual(store.completionFailureCount, 0)
    }

    func testCompletesItemsBeyondCollapsedPreview() async throws {
        let store = try store()
        await store.refresh()
        let open = store.items.filter(\.isOpen)
        XCTAssertGreaterThan(open.count, TodayCommitmentsCard.rowLimit)
        await store.completeAll(open)
        XCTAssertFalse(store.items.contains(where: \.isOpen))
    }

    func testSnapshotCannotWriteAfterOwnershipChanges() async throws {
        let store = try store()
        await store.refresh()
        let before = store.items
        DemoMode.set(false)
        await store.completeAll(before.filter(\.isOpen))
        XCTAssertEqual(store.items, before)
        XCTAssertFalse(store.isCompletingAll)
    }

    func testEmptyConfirmationDoesNothing() async throws {
        let store = try store()
        await store.refresh()
        let before = store.items
        await store.completeAll([])
        XCTAssertEqual(store.items, before)
        XCTAssertFalse(store.isCompletingAll)
    }
}
