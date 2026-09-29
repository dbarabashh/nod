import XCTest
@testable import Nod

/// The client's words and the server's allow-list have to agree: an event or
/// a value the migration does not know is refused as `invalid_properties`,
/// silently, which is how four events went unrecorded for a week.
final class ProductEventVocabularyTests: XCTestCase {
    private var migration: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("supabase/migrations/20260929185505_memory_activation_stages.sql")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func testEveryEventIsAcceptedByTheServer() {
        let sql = migration
        XCTAssertFalse(sql.isEmpty)
        for event in ProductAnalytics.Event.allCases {
            XCTAssertTrue(sql.contains("'\(event.rawValue)'"), "\(event.rawValue) is not on the allow-list")
        }
    }

    func testEveryDetailOutcomeAndReasonIsAcceptedByTheServer() {
        let sql = migration
        for detail in ProductAnalytics.Detail.allCases {
            XCTAssertTrue(sql.contains("'\(detail.rawValue)'"), "detail \(detail.rawValue) is not on the allow-list")
        }
        for outcome in ProductAnalytics.Outcome.allCases {
            XCTAssertTrue(sql.contains("'\(outcome.rawValue)'"), "outcome \(outcome.rawValue) is not on the allow-list")
        }
        for reason in ProductAnalytics.ReasonCode.allCases {
            XCTAssertTrue(sql.contains("'\(reason.rawValue)'"), "reason \(reason.rawValue) is not on the allow-list")
        }
        for surface in ProductAnalytics.Surface.allCases {
            XCTAssertTrue(sql.contains("'\(surface.rawValue)'"), "surface \(surface.rawValue) is not on the allow-list")
        }
    }

    func testAMoveIsCountedForWhatItWas() {
        XCTAssertEqual(ActionItemStore.moveOutcome(to: .confirmed, by: .user), .done)
        XCTAssertEqual(ActionItemStore.moveOutcome(to: .open, by: .user), .reopened)
        XCTAssertEqual(ActionItemStore.moveOutcome(to: .probablyDone, by: .external), .autoClosed)
        XCTAssertEqual(ActionItemStore.moveOutcome(to: .open, by: .system), .reopened)
    }

    func testACustomModeNeverSendsItsName() {
        var mode = MeetingMode.presets[0]
        mode.name = "Board prep with Anna"
        XCTAssertEqual(ModeStore.detail(of: mode), .custom)
        XCTAssertEqual(ModeStore.detail(of: MeetingMode.presets[0]), .general)
    }
}
