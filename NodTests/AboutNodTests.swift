import XCTest
@testable import Nod

/// The one conversation that decides whether somebody records anything.
///
/// A question about Nod has no session to ground on, so left to the model it
/// would be answered from whatever it believes about a macOS app it has never
/// seen. These pin that the prepared answers are reachable, and — more
/// importantly — that they do not hijack a real question.
final class AboutNodTests: XCTestCase {
    func testEveryPreparedQuestionIsAnswerable() {
        for prepared in AboutNod.prepared {
            XCTAssertEqual(AboutNod.answer(to: prepared.question), prepared.answer)
        }
    }

    func testNoPreparedAnswerIsEmpty() {
        for prepared in AboutNod.prepared {
            XCTAssertFalse(prepared.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prepared.question)
        }
    }

    /// Typed by hand, the same question arrives with different case, spacing
    /// and no question mark.
    func testMatchingSurvivesHowPeopleActuallyType() {
        let asked = ["what can nod do", "  What   can Nod do?  ", "WHAT CAN NOD DO?"]

        for question in asked {
            XCTAssertNotNil(AboutNod.answer(to: question), question)
        }
    }

    /// The important half. A question about the user's own sessions that
    /// happens to contain one of ours must reach retrieval, not the pitch.
    func testAQuestionThatMerelyContainsOursIsNotHijacked() {
        let real = [
            "What can Nod do about the pricing decision?",
            "How do I get set up for the Berlin conference?",
            "What did Nod do last week?"
        ]

        for question in real {
            XCTAssertNil(AboutNod.answer(to: question), question)
        }
    }

    /// The matcher runs on the raw question, before query prep rewrites it.
    ///
    /// It used to sit in the router, which a question the model decides needs
    /// no sessions never reaches when a tool is connected — so the one thing
    /// that must never be improvised was improvised for exactly the users who
    /// had set Nod up furthest.
    func testTheOpenersMatchTheTextAsTyped() {
        for question in AboutNod.questions {
            XCTAssertNotNil(AboutNod.answer(to: question), question)
        }
    }

    func testAnUnrelatedQuestionIsNotAnswered() {
        XCTAssertNil(AboutNod.answer(to: "What did I promise?"))
        XCTAssertNil(AboutNod.answer(to: ""))
    }

    /// The copy names no integration.
    ///
    /// Which products a person has connected is theirs, not ours — naming ours
    /// tells somebody who connected none, or something else, about a Nod they
    /// do not have. It also ties the pitch to a catalogue that changes: the day
    /// a provider is added or dropped, prose written months earlier is what
    /// goes stale, and nothing points at it.
    func testTheCopyNamesNoParticularIntegration() {
        let copy = AboutNod.prepared.map(\.answer).joined(separator: "\n")

        for provider in IntegrationProvider.allCases {
            XCTAssertFalse(copy.contains(provider.displayName), provider.displayName)
        }
    }

    /// The one claim in here that is a promise rather than a description. If
    /// this ever stops being true the copy has to change in the same commit —
    /// and if the wording drifts, the denial has to survive the rewrite.
    func testTheScreenAnswerDeniesScreenshotsOutright() {
        let answer = try? XCTUnwrap(AboutNod.answer(to: "Does Nod watch my screen?"))
        let copy = answer ?? ""

        XCTAssertTrue(copy.localizedCaseInsensitiveContains("no screenshots"), copy)
        XCTAssertTrue(copy.localizedCaseInsensitiveContains("off until you turn it on"), copy)
    }

    /// "Off until you turn it on" has to be true of a fresh install, not of the
    /// machine running the test — `isEnabled` reads a real file, so asking it
    /// here would only report whether this developer switched ambient on.
    /// The pure resolver is the seam its own author left for exactly this.
    func testAFreshInstallHasAmbientContextOff() {
        XCTAssertFalse(ScreenContextDefaults.resolveEnabled(fileByte: nil, legacyFlag: false))
    }

    /// Nothing here may describe a feature that does not exist.
    func testTheCopyClaimsNothingNodCannotDo() {
        let copy = AboutNod.prepared.map(\.answer).joined(separator: "\n")

        // Platforms Nod does not ship on. Not "Windows" — the copy talks about
        // windows on screen, and the collision would fail on the wrong word.
        for absent in ["iPhone", "iPad", "Android", "Microsoft"] {
            XCTAssertFalse(copy.localizedCaseInsensitiveContains(absent), absent)
        }
    }
}
