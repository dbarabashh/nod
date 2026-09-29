import XCTest
@testable import Nod

final class MemoryActivationTests: XCTestCase {
    func testEnabledSwitchAloneDoesNotMeanContextIsReady() {
        XCTAssertEqual(stage(ready: nil), .checking)
        XCTAssertEqual(stage(ready: false), .waiting)
        XCTAssertEqual(stage(ready: true), .ready)
    }

    func testConsentPauseAndPermissionOverrideCachedAvailability() {
        XCTAssertEqual(stage(enabled: false, ready: true), .off)
        XCTAssertEqual(stage(paused: true, ready: true), .paused)
        XCTAssertEqual(stage(needsAccess: true, ready: true), .permission)
        XCTAssertEqual(stage(ready: true, failed: true), .failed)
    }

    func testDismissalCompletionAndEntitlementHideTheOffer() {
        XCTAssertEqual(stage(eligible: false, ready: true), .hidden)
        XCTAssertEqual(stage(dismissed: true, ready: true), .hidden)
        XCTAssertEqual(stage(completed: true, ready: true), .hidden)
    }

    func testCompletionIsAccountScoped() {
        XCTAssertNotEqual(MemoryActivation.completionKey(UUID()), MemoryActivation.completionKey(UUID()))
    }

    func testAmbientOpenerRequiresAvailableContextAndDoesNotOverrideProjectScope() {
        let empty = ChatHomeSuggestions.build(meetings: [])
        XCTAssertFalse(empty.contains { $0.question == MemoryActivation.question })
        let ready = ChatHomeSuggestions.build(meetings: [], hasAmbientContext: true)
        XCTAssertEqual(ready.first?.question, MemoryActivation.question)
        let scoped = ChatHomeSuggestions.build(meetings: [], projects: ["Launch"], hasAmbientContext: true)
        XCTAssertFalse(scoped.contains { $0.question == MemoryActivation.question })
        let preview = ChatHomeSuggestions.build(meetings: [], firstRunPreview: true, hasAmbientContext: true)
        XCTAssertFalse(preview.contains { $0.question == MemoryActivation.question })
    }

    private func stage(
        eligible: Bool = true,
        dismissed: Bool = false,
        completed: Bool = false,
        enabled: Bool = true,
        needsAccess: Bool = false,
        paused: Bool = false,
        ready: Bool? = nil,
        failed: Bool = false
    ) -> MemoryActivation.Stage {
        MemoryActivation.stage(
            eligible: eligible,
            dismissed: dismissed,
            completed: completed,
            enabled: enabled,
            needsAccess: needsAccess,
            paused: paused,
            ready: ready,
            failed: failed
        )
    }
}
