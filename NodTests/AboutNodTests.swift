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

    private var screenAnswer: String {
        AboutNod.answer(to: "Does Nod watch my screen?") ?? ""
    }

    /// The claims that are promises rather than descriptions. If any stops
    /// being true the copy has to change in the same commit.
    func testTheScreenAnswerKeepsItsPromises() {
        XCTAssertTrue(screenAnswer.localizedCaseInsensitiveContains("off until you turn it on"), screenAnswer)
        XCTAssertTrue(screenAnswer.localizedCaseInsensitiveContains("never stored"), screenAnswer)
        XCTAssertTrue(screenAnswer.contains("\(ScreenContextDefaults.defaultRetentionDays) days by"), screenAnswer)
    }

    /// This copy used to say Nod took no pictures of the screen and that there
    /// was no code in it that could. `ScreenTextRecognizer` is that code: when
    /// accessibility comes up short it captures the one window with
    /// `SCScreenshotManager` and reads it with Vision. The image is dropped in
    /// the same call and only the text survives — which is a promise worth
    /// making, and a very different one from the denial that was there.
    ///
    /// A flat denial is worse than the truth: the day somebody finds the
    /// capture call, every other claim on this screen goes with it.
    func testTheScreenAnswerDoesNotDenyWhatTheCodeDoes() {
        for denial in ["no screenshots", "takes no pictures", "nothing visual is captured"] {
            XCTAssertFalse(screenAnswer.localizedCaseInsensitiveContains(denial), denial)
        }
    }

    /// The default the copy quotes has to be the default in code.
    func testTheQuotedRetentionMatchesTheDefault() {
        XCTAssertEqual(ScreenContextDefaults.defaultRetentionDays, 14)
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

/// The grounding half: the prepared answers are matched on the exact question,
/// which a person typing rarely produces — least of all in another language.
/// Asked "чи ти робиш скріншоти?", Nod had nothing to ground on and said it
/// could not name the retention period. True, useless, and about the one
/// subject where a shrug costs the most trust.
final class AboutNodGroundingTests: XCTestCase {
    func testItAnswersTheQuestionsPeopleActuallyType() {
        let asked = [
            "а ти робиш скріншоти?",
            "ти запам'ятовуєш всю інфу з екрану? через місяць будеш памятати?",
            "як довго зберігаються мої дані",
            "do you take screenshots?",
            "how long do you keep this",
            "will you remember this in a month?",
            "are you SOC 2 compliant?"
        ]

        for question in asked {
            XCTAssertNotNil(AboutNod.grounding(for: question), question)
        }
    }

    /// It must not fire on an ordinary question about the user's own work, or
    /// every answer pays for a block about Nod's plumbing.
    func testItStaysOutOfOrdinaryQuestions() {
        let ordinary = [
            "what did I promise?",
            "що я робив сьогодні?",
            "catch me up on the pricing call",
            "what did we decide this week?"
        ]

        for question in ordinary {
            XCTAssertNil(AboutNod.grounding(for: question), question)
        }
    }

    /// The three claims that would be lies, and the one denial that was one.
    func testTheGroundingRefusesTheClaimsWeCannotMake() {
        let facts = AboutNod.grounding(for: "do you take screenshots?") ?? ""

        XCTAssertTrue(facts.contains("Do not deny the capture"), facts)
        XCTAssertTrue(facts.contains("Never claim redaction"), facts)
        XCTAssertTrue(facts.localizedCaseInsensitiveContains("no SOC 2"), facts)
    }

    /// The numbers in the block are the numbers in the code.
    func testTheGroundingQuotesTheRealRetention() {
        let facts = AboutNod.grounding(for: "how long do you keep this") ?? ""

        XCTAssertTrue(facts.contains("\(ScreenContextDefaults.defaultRetentionDays) days by default"), facts)
        XCTAssertTrue(facts.contains("7, 14 or 30"), facts)
    }
}
