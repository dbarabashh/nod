import XCTest
@testable import Nod

final class MainThreadTests: XCTestCase {
    @MainActor
    func testRunsTheOperationAndReturnsItsValue() {
        var ran = false
        let value = MainActor.assumeMainThread {
            ran = true
            return 42
        }
        XCTAssertTrue(ran)
        XCTAssertEqual(value, 42)
    }

    @MainActor
    func testRethrows() {
        struct Failure: Error {}
        XCTAssertThrowsError(try MainActor.assumeMainThread { throw Failure() })
    }
}
