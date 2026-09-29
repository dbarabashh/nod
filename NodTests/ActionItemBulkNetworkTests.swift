import Foundation
import XCTest
@testable import Nod

private actor ActionItemHTTPBackend {
    let rows: Data
    let emptyID: UUID?
    let rejectedID: UUID?
    let heldID: UUID?
    private(set) var patched: [UUID] = []
    private(set) var transitions = 0
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    init(items: [ActionItem], emptyID: UUID? = nil, rejectedID: UUID? = nil, heldID: UUID? = nil) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(items)) as? [[String: Any]])
        for index in items.indices {
            records[index]["external_provider"] = items[index].externalProvider
            records[index]["external_key"] = items[index].externalKey
            records[index]["external_url"] = items[index].externalURL
        }
        rows = try JSONSerialization.data(withJSONObject: records)
        self.emptyID = emptyID
        self.rejectedID = rejectedID
        self.heldID = heldID
    }

    func respond(_ request: URLRequest) async throws -> (Int, Data) {
        guard let url = request.url else { throw URLError(.badURL) }
        if request.httpMethod == "GET", url.path.hasSuffix("action_items") { return (200, rows) }
        if request.httpMethod == "PATCH" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let raw = query.first(where: { $0.name == "id" })?.value,
                  let id = UUID(uuidString: String(raw.dropFirst(3))) else { throw URLError(.badURL) }
            patched.append(id)
            started?.resume()
            started = nil
            if id == heldID { await withCheckedContinuation { release = $0 } }
            if id == emptyID { return (200, Data("[]".utf8)) }
            if id == rejectedID {
                return (400, Data("{\"code\":\"23514\",\"message\":\"test rejection\"}".utf8))
            }
            return (200, Data("[{\"id\":\"\(id)\"}]".utf8))
        }
        if request.httpMethod == "POST", url.path.hasSuffix("action_item_transitions") {
            transitions += 1
            return (201, Data("[]".utf8))
        }
        throw URLError(.unsupportedURL)
    }

    func waitForPatch() async {
        if !patched.isEmpty { return }
        await withCheckedContinuation { started = $0 }
    }

    func releasePatch() {
        release?.resume(); release = nil
    }
}

@MainActor
final class ActionItemBulkNetworkTests: XCTestCase {
    private var wasDemoEnabled = false

    override func setUp() {
        super.setUp()
        wasDemoEnabled = DemoMode.isEnabled
        DemoMode.set(false)
    }

    override func tearDown() {
        DemoMode.set(wasDemoEnabled)
        super.tearDown()
    }

    private func items(owner: UUID) throws -> [ActionItem] {
        try (0 ..< 3).map { (index: Int) in
            try ActionItem.new(meetingID: UUID(), userID: owner, text: "Task \(index)", deadline: nil, position: index)
                .filed(in: ProviderLinkItem(
                    provider: .linear,
                    title: "TEST-\(index)",
                    url: XCTUnwrap(URL(string: "https://linear.app/test/issue/TEST-\(index)"))
                ), at: Date())
        }
    }

    func testHTTPAndZeroRowFailuresDoNotMirrorAndRemainingTasksContinue() async throws {
        let owner = UUID()
        let rows = try items(owner: owner)
        let backend = try ActionItemHTTPBackend(items: rows, emptyID: rows[0].id, rejectedID: rows[1].id)
        let fixture = try await LocalHTTPFixture(userID: owner) { try await backend.respond($0) }
        var mirrored: [String] = []
        let store = ActionItemStore(supabase: fixture.client) { reference, _ in mirrored.append(reference.title) }
        await store.refresh()
        XCTAssertEqual(store.items.count, 3)
        await store.completeAll(rows)
        XCTAssertEqual(store.items.map(\.done), [false, false, true])
        XCTAssertEqual(store.completionFailureCount, 2)
        XCTAssertFalse(store.isCompletingAll)
        XCTAssertEqual(mirrored, ["TEST-2"])
        let transitions = await backend.transitions
        XCTAssertEqual(transitions, 1)
        await fixture.close()
    }

    func testAccountClearDuringWriteStopsRemainingTasksAndMirroring() async throws {
        let owner = UUID()
        let rows = try items(owner: owner)
        let backend = try ActionItemHTTPBackend(items: rows, heldID: rows[0].id)
        let fixture = try await LocalHTTPFixture(userID: owner) { try await backend.respond($0) }
        var mirrored = false
        let store = ActionItemStore(supabase: fixture.client) { _, _ in mirrored = true }
        await store.refresh()
        let task = Task { await store.completeAll(rows) }
        await backend.waitForPatch()
        store.clear()
        await backend.releasePatch()
        await task.value
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(store.isCompletingAll)
        XCTAssertFalse(mirrored)
        let patched = await backend.patched
        let transitions = await backend.transitions
        XCTAssertEqual(patched, [rows[0].id])
        XCTAssertEqual(transitions, 0)
        await fixture.close()
    }
}
