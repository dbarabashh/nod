import XCTest
@testable import Nod

/// Covers the safety-critical clamp in `TranscriptStore.orderedInsertionIndex`
/// (NOD-29): a retried segment must slot into timestamp order, but must never be
/// placed ahead of an entry old enough to have already been streamed to the
/// server under a positional `idx` — reordering that prefix would corrupt the
/// `meeting_id,idx` upsert key.
final class TranscriptOrderingTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 10_000)
    private let horizon: TimeInterval = 10

    private func index(_ offsets: [TimeInterval], inserting: TimeInterval) -> Int {
        let timestamps = offsets.map { now.addingTimeInterval($0) }
        return TranscriptStore.orderedInsertionIndex(
            count: timestamps.count,
            timestampAt: { timestamps[$0] },
            inserting: now.addingTimeInterval(inserting),
            now: now,
            horizon: horizon
        )
    }

    func testEmptyInsertsAtZero() {
        XCTAssertEqual(index([], inserting: -1), 0)
    }

    func testNewestLiveChunkAppendsAtTail() {
        // Normal live path: each chunk is the newest, so it lands at the end and
        // behaves exactly like the old append.
        XCTAssertEqual(index([-30, -5], inserting: -1), 2)
    }

    func testLateArrivalWithinHorizonInsertsChronologically() {
        // A segment recovered a few seconds late slots between its neighbours.
        XCTAssertEqual(index([-8, -2], inserting: -5), 1)
    }

    func testDeepRecoveryIsClampedAfterStreamedPrefix() {
        // -25 chronologically belongs between -30 and -20, but both predate the
        // horizon (already streamed), so it's clamped to just after them (index
        // 2) instead of repositioning a streamed entry.
        XCTAssertEqual(index([-30, -20, -2], inserting: -25), 2)
    }

    func testEqualTimestampKeepsArrivalOrder() {
        // Ties insert after the existing entry, preserving arrival order.
        XCTAssertEqual(index([-3], inserting: -3), 1)
    }

    func testInsertBeforeAllReorderableEntries() {
        // Newer than the horizon but older than every current entry → goes to the
        // front of the reorderable region (here the whole array is reorderable).
        XCTAssertEqual(index([-4, -2], inserting: -6), 0)
    }

    func testStreamedPrefixNeverShiftsAcrossManyEntries() {
        // Every entry older than the horizon is a fixed streamed prefix; a late
        // arrival can only ever land at or after that boundary.
        let offsets: [TimeInterval] = [-40, -30, -20, -13, -11, -4, -1]
        let floorIndex = offsets.filter { $0 < -horizon }.count // = 5
        for inserting in stride(from: -45.0, through: 0.0, by: 1.0) {
            XCTAssertGreaterThanOrEqual(
                index(offsets, inserting: inserting),
                floorIndex,
                "inserting \(inserting) breached the streamed prefix"
            )
        }
    }
}
