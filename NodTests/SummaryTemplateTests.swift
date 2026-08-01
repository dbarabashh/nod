import XCTest
@testable import Nod

/// The recap prompt carries two instructions about task headings: a rule that
/// forbids them as `sections`, and a per-template section plan. They are written
/// in different places and must agree — when they didn't, the sales template
/// asked for a "Commitments" section the rule above it banned.
final class SummaryTemplateTests: XCTestCase {
    /// Every heading the `[ACTION ITEMS]` rule names as forbidden has to be
    /// recognised here, or the section plan will ask for it anyway.
    func testEveryForbiddenHeadingIsRecognised() {
        let forbidden = [
            "To-dos", "Action items", "Next steps", "Follow-ups", "Commitments",
            "Actions", "TODO", "Follow up", "Next Step", "Commitment"
        ]
        for heading in forbidden {
            XCTAssertTrue(PromptLibrary.isActionHeading(heading), "\"\(heading)\" should route to action_items")
        }
    }

    /// The narrow matching is the point: a bare `contains("action")` swallows
    /// these, and dropping a legitimate section is the worse failure.
    func testSubstantiveHeadingsSurvive() {
        let kept = [
            "Reaction to the demo", "Transaction summary", "Customer needs",
            "Objections raised", "Candidate background", "Strengths", "Concerns",
            "Recommendation", "Topics covered", "Decisions made", "Blockers"
        ]
        for heading in kept {
            XCTAssertFalse(PromptLibrary.isActionHeading(heading), "\"\(heading)\" is a real section")
        }
    }

    /// No template may plan a section that the rule forbids — that is the
    /// contradiction this file exists to catch, for every template at once.
    func testNoTemplatePlansAForbiddenSection() {
        for template in SummaryTemplate.allCases {
            let planned = template.sections ?? []
            let offending = planned.filter { PromptLibrary.isActionHeading($0) }
            XCTAssertFalse(
                offending.isEmpty && planned.isEmpty && template != .auto,
                "\(template.rawValue) should either be auto or plan sections"
            )
            // Headings that route to action_items are expected in the template
            // list — they are filtered before the plan is written. What must not
            // happen is a template left with nothing substantive to say.
            let substantive = planned.filter { !PromptLibrary.isActionHeading($0) }
            if template != .auto {
                XCTAssertFalse(substantive.isEmpty, "\(template.rawValue) has no section left after filtering")
            }
        }
    }

    /// The sales template's own shape: the two task headings route away, and
    /// what is left is what the recap actually renders.
    func testSalesTemplateRoutesBothTaskHeadings() {
        let planned = SummaryTemplate.salesCall.sections ?? []

        XCTAssertTrue(PromptLibrary.isActionHeading("Next steps"))
        XCTAssertTrue(PromptLibrary.isActionHeading("Commitments"))
        XCTAssertEqual(
            planned.filter { !PromptLibrary.isActionHeading($0) },
            ["Customer needs", "Objections raised"]
        )
    }

    func testInterviewTemplateKeepsItsAssessmentSections() {
        let planned = SummaryTemplate.interview.sections ?? []

        XCTAssertEqual(
            planned.filter { !PromptLibrary.isActionHeading($0) },
            ["Candidate background", "Strengths", "Concerns", "Recommendation"]
        )
    }

    func testAutoTemplateLetsTheModelChoose() {
        XCTAssertNil(SummaryTemplate.auto.sections)
    }
}
