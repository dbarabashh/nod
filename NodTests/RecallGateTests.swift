import XCTest
@testable import Nod

final class RecallGateTests: XCTestCase {
    func testOneQuestionPerCandidateOverTheEndOfTheWindow() {
        let window = String(repeating: "a", count: 9000) + "the pricing deck"
        let request = RecallGate.request(window: window, candidates: ["Send Anna the deck", String(repeating: "b", count: 5000)])

        XCTAssertEqual(request.questions.count, 2)
        XCTAssertEqual(request.state.said.count, RecallGate.saidLength)
        XCTAssertTrue(request.state.said.hasSuffix("the pricing deck"))
        XCTAssertEqual(request.state.candidates[1].count, RecallGate.candidateLength)
    }

    /// A wrong no is a reminder nobody ever sees, so only a sure no removes one.
    func testOnlyASureNoRulesACandidateOut() {
        let answers = [
            "candidate_0": JudgeAnswer(noul: 0.05),
            "candidate_1": JudgeAnswer(noul: 0.3),
            "candidate_2": JudgeAnswer(noul: 0.9)
        ]

        XCTAssertEqual(RecallGate.kept(4, given: answers), [1, 2, 3], "an unanswered candidate stays in")
        XCTAssertEqual(RecallGate.kept(2, given: [:]), [0, 1])
    }
}
