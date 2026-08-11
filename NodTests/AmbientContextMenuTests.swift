import AppKit
import SwiftUI
import XCTest
@testable import Nod

/// Nothing here writes the real `ambient-context.*` files: they are the flags
/// that decide whether Nod reads the screen, and a test that left one behind
/// would change that for whoever ran the suite. The rules are pure, so they are
/// tested as rules.
@MainActor
final class AmbientContextMenuTests: XCTestCase {
    // MARK: - Pause durations

    func testFixedPausesAreTheirStatedLength() {
        let now = Date()
        XCTAssertEqual(AmbientPauseChoice.fifteenMinutes.duration(from: now), 15 * 60)
        XCTAssertEqual(AmbientPauseChoice.hour.duration(from: now), 60 * 60)
    }

    /// "Until Tomorrow" has to mean the same thing whenever it's picked — a
    /// fixed span would run into the next day when chosen in the evening.
    func testUntilTomorrowEndsAtMidnightWheneverItIsChosen() throws {
        var calendar = Calendar(identifier: .gregorian)
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Kyiv"))
        calendar.timeZone = zone

        for hour in [0, 9, 17, 23] {
            let now = try XCTUnwrap(
                calendar.date(from: DateComponents(timeZone: zone, year: 2026, month: 7, day: 31, hour: hour, minute: 30))
            )
            let end = now.addingTimeInterval(AmbientPauseChoice.untilTomorrow.duration(from: now, calendar: calendar))
            XCTAssertEqual(
                end,
                calendar.startOfDay(for: now).addingTimeInterval(24 * 60 * 60),
                "a pause chosen at \(hour):30 should end at midnight"
            )
            XCTAssertTrue(end > now, "a pause must always end in the future")
        }
    }

    /// A DST day is 23 or 25 hours long. Adding a flat 86 400 s to its start
    /// lands an hour either side of midnight — resuming capture early on the
    /// fall-back day, which is the direction that matters.
    func testUntilTomorrowSurvivesADaylightSavingTransition() throws {
        var calendar = Calendar(identifier: .gregorian)
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Kyiv"))
        calendar.timeZone = zone

        // 2026-10-25 is the European fall-back day: 25 hours long.
        for day in [25, 26] {
            let now = try XCTUnwrap(
                calendar.date(from: DateComponents(timeZone: zone, year: 2026, month: 10, day: day, hour: 9))
            )
            let end = now.addingTimeInterval(AmbientPauseChoice.untilTomorrow.duration(from: now, calendar: calendar))
            let components = calendar.dateComponents([.hour, .minute], from: end)

            XCTAssertEqual(components.hour, 0, "a pause should end at midnight, not \(components.hour ?? -1):00")
            XCTAssertEqual(components.minute, 0)
            XCTAssertEqual(end, AmbientPauseChoice.startOfNextDay(after: now, calendar: calendar))
        }
    }

    // MARK: - Delete windows

    func testEverythingHasNoLowerBound() {
        XCTAssertNil(AmbientDeleteChoice.everything.cutoff(from: Date()))
    }

    func testScopedDeletesCarryTheirStatedWindow() {
        let now = Date()
        XCTAssertEqual(AmbientDeleteChoice.fiveMinutes.cutoff(from: now)?.timeIntervalSince(now) ?? 0, -5 * 60, accuracy: 0.001)
        XCTAssertEqual(AmbientDeleteChoice.fifteenMinutes.cutoff(from: now)?.timeIntervalSince(now) ?? 0, -15 * 60, accuracy: 0.001)
        XCTAssertEqual(AmbientDeleteChoice.hour.cutoff(from: now)?.timeIntervalSince(now) ?? 0, -60 * 60, accuracy: 0.001)
    }

    /// A delete that removed nothing and a delete that failed are different
    /// facts, and the user acts differently on each.
    func testDeletionMessageDistinguishesEmptyFromFailed() {
        XCTAssertEqual(
            AmbientContextSidebarRow.deletionMessage(.deleted(count: 0, appName: nil)),
            "Nothing captured in that window."
        )
        XCTAssertEqual(
            AmbientContextSidebarRow.deletionMessage(.deleted(count: 1, appName: nil)),
            "Deleted 1 capture."
        )
        XCTAssertEqual(
            AmbientContextSidebarRow.deletionMessage(.deleted(count: 12, appName: nil)),
            "Deleted 12 captures."
        )
        XCTAssertNotEqual(
            AmbientContextSidebarRow.deletionMessage(.failed),
            AmbientContextSidebarRow.deletionMessage(.deleted(count: 0, appName: nil))
        )
    }

    /// A per-app delete (Settings › Privacy) and a time-window delete (the
    /// sidebar menu) share one `lastDeletion` — whichever fired last has to
    /// name its own scope, or it reads as the other surface's action.
    func testDeletionMessageNamesTheAppWhenScoped() {
        XCTAssertEqual(
            AmbientContextSidebarRow.deletionMessage(.deleted(count: 0, appName: "Slack")),
            "Nothing captured from Slack."
        )
        XCTAssertEqual(
            AmbientContextSidebarRow.deletionMessage(.deleted(count: 1, appName: "Slack")),
            "Deleted 1 capture from Slack."
        )
        XCTAssertEqual(
            AmbientContextSidebarRow.deletionMessage(.deleted(count: 12, appName: "Slack")),
            "Deleted 12 captures from Slack."
        )
    }

    // MARK: - Confirmation copy

    /// Every destructive or widening action must state what it does before it
    /// happens. A blank message is how one ships without saying anything.
    func testEveryConfirmationSaysSomething() {
        let cases: [AmbientConfirmation] = [.enable] + AmbientDeleteChoice.allCases.map { .delete($0) }
        for pending in cases {
            XCTAssertFalse(AmbientContextSidebarRow.confirmationTitle(pending).isEmpty, "\(pending) needs a title")
            XCTAssertFalse(
                AmbientContextSidebarRow.confirmationMessage(pending, retentionDays: 14).isEmpty,
                "\(pending) needs a message"
            )
        }
    }

    /// The enable dialog is the disclosure — consent is the legal basis for
    /// ambient capture, and it is the only place a menu can carry one.
    func testEnableConfirmationCarriesTheDisclosure() {
        let message = AmbientContextSidebarRow.confirmationMessage(.enable, retentionDays: 14)
        XCTAssertTrue(message.contains("Excluded apps and sites are never read"))
        XCTAssertTrue(message.contains("no images are ever saved"))
        XCTAssertTrue(message.contains("14 days"))
    }

    /// Retention is selectable, so the disclosure has to quote the setting the
    /// user is actually on — not the default they may have changed.
    func testEnableConfirmationQuotesTheChosenRetention() {
        XCTAssertTrue(AmbientContextSidebarRow.confirmationMessage(.enable, retentionDays: 30).contains("30 days"))
        XCTAssertFalse(AmbientContextSidebarRow.confirmationMessage(.enable, retentionDays: 7).contains("14 days"))
    }

    func testDeleteConfirmationSaysItIsIrreversibleAndScoped() {
        let message = AmbientContextSidebarRow.confirmationMessage(.delete(.everything), retentionDays: 14)
        XCTAssertTrue(message.contains("can't be recovered"))
        XCTAssertTrue(message.contains("sessions and transcripts are not affected"))
    }

    // MARK: - Pause resolution

    /// A deadline that has already passed is not a pause — otherwise quitting
    /// during one would leave capture suppressed after it should have resumed.
    func testExpiredPauseResolvesToNothing() {
        let now = Date()
        XCTAssertNil(ScreenContextDefaults.resolvePause(deadline: now.addingTimeInterval(-1), now: now))
        XCTAssertNil(ScreenContextDefaults.resolvePause(deadline: now, now: now))
        XCTAssertNil(ScreenContextDefaults.resolvePause(deadline: nil, now: now))
    }

    func testLivePauseResolvesToItsDeadline() {
        let now = Date()
        let until = now.addingTimeInterval(900)
        XCTAssertEqual(ScreenContextDefaults.resolvePause(deadline: until, now: now), until)
    }

    // MARK: - State labels

    /// One name per `ActivityState`, so the invariants below can be driven off
    /// `allCases` instead of a hand-written list. `kind(of:)` is the enforcement:
    /// it fails to compile when a state is added, which is what stops a new case
    /// from silently sitting outside both guarantees — `.notEntitled` was added
    /// and did exactly that.
    private enum StateKind: CaseIterable {
        case off, notEntitled, needsAccessibility, paused, on
    }

    private static func state(for kind: StateKind, now: Date) -> ScreenContextService.ActivityState {
        switch kind {
        case .off: .off
        case .notEntitled: .notEntitled
        case .needsAccessibility: .needsAccessibility
        case .paused: .paused(until: now.addingTimeInterval(900))
        case .on: .on
        }
    }

    private static func kind(of state: ScreenContextService.ActivityState) -> StateKind {
        switch state {
        case .off: .off
        case .notEntitled: .notEntitled
        case .needsAccessibility: .needsAccessibility
        case .paused: .paused
        case .on: .on
        }
    }

    private static func allStates(now: Date) -> [ScreenContextService.ActivityState] {
        StateKind.allCases.map { state(for: $0, now: now) }
    }

    /// Fails if a state exists that the list above doesn't build — the guard that
    /// keeps the two invariants below honest.
    func testEveryStateIsCovered() {
        let now = Date()
        let kinds = Self.allStates(now: now).map { Self.kind(of: $0) }
        XCTAssertEqual(Set(kinds).count, StateKind.allCases.count)
    }

    /// Every state has to read differently. Two that render the same word are
    /// how "on but doing nothing" gets mistaken for running.
    func testEveryStateReadsDifferently() {
        let now = Date()
        let states = Self.allStates(now: now)
        XCTAssertEqual(Set(states.map { $0.label(now: now) }).count, states.count)
    }

    /// The row has to say how long is left, or "Paused" leaves the user unable
    /// to tell a coffee break from the rest of the day.
    func testPausedLabelCarriesTheTimeLeft() {
        let now = Date()
        XCTAssertEqual(
            ScreenContextService.ActivityState.paused(until: now.addingTimeInterval(42 * 60)).label(now: now),
            "Paused 42m"
        )
        XCTAssertEqual(
            ScreenContextService.ActivityState.paused(until: now.addingTimeInterval(3 * 3600)).label(now: now),
            "Paused 3h"
        )
    }

    func testRemainingIsCoarseAndNeverNegative() {
        let now = Date()
        XCTAssertEqual(ScreenContextService.ActivityState.remaining(until: now.addingTimeInterval(30), from: now), "<1m")
        XCTAssertEqual(ScreenContextService.ActivityState.remaining(until: now.addingTimeInterval(-600), from: now), "<1m")
    }

    /// The sidebar row is 232pt wide and the status sits beside a title. A label
    /// that grows past this truncates the one word that names the feature.
    func testStatusLabelStaysShortEnoughForTheRow() {
        let now = Date()
        for state in Self.allStates(now: now) {
            XCTAssertLessThanOrEqual(state.label(now: now).count, 13, "\(state) is too long for the row")
        }
    }

    // MARK: - Render

    /// The menu is a real control: a crash on mount is invisible to logic tests.
    /// Rendered against the machine's real state, which is left untouched.
    func testRendersWithoutCrashing() {
        let suite = "ambient.menu.\(UUID().uuidString)"
        let exclusions = ScreenExclusions(defaults: UserDefaults(suiteName: suite) ?? .standard, seedDefaults: false)
        let context = ScreenContextService(supabase: nil, exclusions: exclusions)

        // The shipping row, not the menu on its own: the label's layout is the
        // half that broke first, when a menu style laid it out on its own terms
        // and swallowed the status light.
        let host = NSHostingView(rootView: AmbientContextSidebarRow().environmentObject(context))
        host.frame = NSRect(x: 0, y: 0, width: 212, height: 32)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }
}
