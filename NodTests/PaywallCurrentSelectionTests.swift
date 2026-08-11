import XCTest
@testable import Nod

/// Which paywall card is locked as "current plan". Getting this wrong doesn't
/// look like a bug — the button is simply dead, and the person concludes the
/// switch isn't offered. That happened for real: a Pro monthly subscriber found
/// the Pro yearly button disabled, because matching on the plan alone locked both
/// cycle cards.
final class PaywallCurrentSelectionTests: XCTestCase {
    private let catalog: Set<String> = ["pri_pro_monthly", "pri_pro_yearly", "pri_starter_monthly"]

    private func isCurrent(
        isPaid: Bool = true,
        plan: String? = "pro",
        priceID: String?,
        cycle: String?,
        visible: Set<String>? = nil,
        selectedPlan: String = "pro",
        selectedPriceID: String?,
        selectedCycle: String
    ) -> Bool {
        PaywallView.isCurrentSelection(
            isPaid: isPaid,
            currentPlan: plan,
            currentPriceID: priceID,
            currentCycle: cycle,
            visiblePriceIDs: visible ?? catalog,
            selectedPlan: selectedPlan,
            selectedPriceID: selectedPriceID,
            selectedCycle: selectedCycle
        )
    }

    func testExactPriceMatchIsCurrent() {
        XCTAssertTrue(isCurrent(
            priceID: "pri_pro_monthly", cycle: "monthly",
            selectedPriceID: "pri_pro_monthly", selectedCycle: "monthly"
        ))
    }

    func testOtherCycleOfTheSamePlanStaysOffered() {
        XCTAssertFalse(isCurrent(
            priceID: "pri_pro_monthly", cycle: "monthly",
            selectedPriceID: "pri_pro_yearly", selectedCycle: "yearly"
        ))
    }

    func testOtherPlanStaysOffered() {
        XCTAssertFalse(isCurrent(
            priceID: "pri_pro_monthly", cycle: "monthly",
            selectedPlan: "starter",
            selectedPriceID: "pri_starter_monthly", selectedCycle: "monthly"
        ))
    }

    /// A price superseded by a catalogue cutover is hidden from the client by RLS,
    /// so the only way to place the subscriber on a cycle is the resolver's answer.
    func testGrandfatheredPriceLocksOnlyItsOwnCycle() {
        XCTAssertTrue(isCurrent(
            priceID: "pri_pro_monthly_2025", cycle: "monthly",
            selectedPriceID: "pri_pro_monthly", selectedCycle: "monthly"
        ))
        XCTAssertFalse(isCurrent(
            priceID: "pri_pro_monthly_2025", cycle: "monthly",
            selectedPriceID: "pri_pro_yearly", selectedCycle: "yearly"
        ))
    }

    /// A plan granted by hand has no Paddle price, so no cycle can be inferred.
    /// Both cards must stay live — otherwise that account can never buy anything.
    func testHandGrantedPlanLocksNothing() {
        XCTAssertFalse(isCurrent(
            priceID: nil, cycle: nil,
            selectedPriceID: "pri_pro_monthly", selectedCycle: "monthly"
        ))
        XCTAssertFalse(isCurrent(
            priceID: nil, cycle: nil,
            selectedPriceID: "pri_pro_yearly", selectedCycle: "yearly"
        ))
    }

    /// A price the catalogue has never heard of can't be placed on a cycle either.
    func testUnmappedPriceLocksNothing() {
        XCTAssertFalse(isCurrent(
            priceID: "pri_unknown", cycle: nil,
            selectedPriceID: "pri_pro_monthly", selectedCycle: "monthly"
        ))
        XCTAssertFalse(isCurrent(
            priceID: "pri_unknown", cycle: nil,
            selectedPriceID: "pri_pro_yearly", selectedCycle: "yearly"
        ))
    }

    func testTrialUserHasNoCurrentCard() {
        XCTAssertFalse(isCurrent(
            isPaid: false,
            priceID: "pri_pro_monthly", cycle: "monthly",
            selectedPriceID: "pri_pro_monthly", selectedCycle: "monthly"
        ))
    }

    func testCatalogueStillLoadingLocksNothing() {
        XCTAssertFalse(isCurrent(
            priceID: "pri_pro_monthly", cycle: "monthly",
            visible: [],
            selectedPriceID: nil, selectedCycle: "yearly"
        ))
    }
}
