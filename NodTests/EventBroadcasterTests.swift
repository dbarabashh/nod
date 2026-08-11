import XCTest
@testable import Nod

@MainActor
final class EventBroadcasterTests: XCTestCase {
    func testASingleSubscriberFires() {
        let broadcaster = EventBroadcaster<Int>()
        var received: [Int] = []
        broadcaster.subscribe { received.append($0) }

        broadcaster.fire(1)

        XCTAssertEqual(received, [1])
    }

    /// The whole point: a second `subscribe` must not silently discard the
    /// first, the way overwriting a single `var onX: ((T) -> Void)?` would.
    func testASecondSubscriberDoesNotReplaceTheFirst() {
        let broadcaster = EventBroadcaster<Int>()
        var firstCalls = 0
        var secondCalls = 0
        broadcaster.subscribe { _ in firstCalls += 1 }
        broadcaster.subscribe { _ in secondCalls += 1 }

        broadcaster.fire(1)

        XCTAssertEqual(firstCalls, 1)
        XCTAssertEqual(secondCalls, 1)
    }

    func testSubscribersFireInRegistrationOrder() {
        let broadcaster = EventBroadcaster<Int>()
        var order: [String] = []
        broadcaster.subscribe { _ in order.append("first") }
        broadcaster.subscribe { _ in order.append("second") }

        broadcaster.fire(1)

        XCTAssertEqual(order, ["first", "second"])
    }

    func testFiringWithNoSubscribersDoesNothing() {
        let broadcaster = EventBroadcaster<Int>()
        broadcaster.fire(1)
    }

    func testVoidPayloadConvenienceFire() {
        let broadcaster = EventBroadcaster<Void>()
        var fired = false
        broadcaster.subscribe { fired = true }

        broadcaster.fire()

        XCTAssertTrue(fired)
    }
}
