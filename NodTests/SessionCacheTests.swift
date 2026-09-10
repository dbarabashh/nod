import XCTest
@testable import Nod

/// The precedence rules that decide whether a launch keeps its session. Every
/// one of them is a race the keychain cannot be asked to reproduce, and the
/// wrong answer signs a user out.
final class SessionCacheTests: XCTestCase {
    private let key = "supabase.auth.token"
    private let session = Data("session".utf8)
    private let refreshed = Data("refreshed".utf8)

    func testUnreadKeyIsDistinctFromKeyKnownAbsent() {
        var cache = SessionCache()
        XCTAssertNil(cache.value(for: key))

        cache.fill(nil, for: key)

        XCTAssertEqual(cache.value(for: key), .some(nil))
    }

    func testFoundSessionOutranksConcurrentMiss() {
        var cache = SessionCache()

        cache.fill(session, for: key)
        cache.fill(nil, for: key)

        XCTAssertEqual(cache.value(for: key), session)
    }

    func testMissIsReplacedByLaterFind() {
        var cache = SessionCache()

        cache.fill(nil, for: key)
        cache.fill(session, for: key)

        XCTAssertEqual(cache.value(for: key), session)
    }

    func testRemovalOutranksReadStillInFlight() {
        var cache = SessionCache()

        cache.set(nil, for: key)
        cache.fill(session, for: key)

        XCTAssertEqual(cache.value(for: key), .some(nil))
    }

    func testWriteOutranksReadStillInFlight() {
        var cache = SessionCache()

        cache.set(refreshed, for: key)
        cache.fill(session, for: key)

        XCTAssertEqual(cache.value(for: key), refreshed)
    }

    func testOneKeysWriteDoesNotBlockAnothersRead() {
        var cache = SessionCache()

        cache.set(nil, for: "supabase.session")
        cache.fill(session, for: key)

        XCTAssertEqual(cache.value(for: key), session)
    }
}
