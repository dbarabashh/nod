import XCTest
@testable import Nod

/// The annual-saving badge is derived from the catalogue instead of being a
/// hardcoded number, so it can only ever claim a discount that the prices in the
/// same pane actually add up to.
final class PaywallPriceMathTests: XCTestCase {
    func testDiscountFromMonthlyAndAnnualEquivalent() {
        XCTAssertEqual(
            PaywallPriceMath.annualDiscountPercent(monthlyPrice: 24, annualMonthlyEquivalent: 19),
            21
        )
    }

    func testNoDiscountWhenYearlyIsNotCheaper() {
        XCTAssertNil(PaywallPriceMath.annualDiscountPercent(monthlyPrice: 24, annualMonthlyEquivalent: 24))
        XCTAssertNil(PaywallPriceMath.annualDiscountPercent(monthlyPrice: 24, annualMonthlyEquivalent: 30))
    }

    func testFreeMonthlyPriceYieldsNoBadge() {
        XCTAssertNil(PaywallPriceMath.annualDiscountPercent(monthlyPrice: 0, annualMonthlyEquivalent: 0))
    }

    /// One badge for the whole toggle: it may only appear when every plan
    /// discounts by the same amount, so it can't overstate one of them.
    func testCommonDiscountRequiresAgreementAcrossPlans() {
        XCTAssertEqual(PaywallPriceMath.commonAnnualDiscountPercent([20, 20]), 20)
        XCTAssertNil(PaywallPriceMath.commonAnnualDiscountPercent([20, 25]))
        XCTAssertNil(PaywallPriceMath.commonAnnualDiscountPercent([20, nil]))
        XCTAssertNil(PaywallPriceMath.commonAnnualDiscountPercent([]))
    }
}
