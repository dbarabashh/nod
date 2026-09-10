import XCTest
@testable import Nod

final class BeatIntentTests: XCTestCase {
    func testBeatsAreAskedAboutByWordNotBySubstring() {
        XCTAssertTrue(QuestionIntent.asksAboutBeats("what did my morning beat find?"))
        XCTAssertTrue(QuestionIntent.asksAboutBeats("What did I miss today?"))
        XCTAssertTrue(QuestionIntent.asksAboutBeats("що нового по проєкту?"))
        XCTAssertFalse(QuestionIntent.asksAboutBeats("my heartbeat was high on the run"))
        XCTAssertFalse(QuestionIntent.asksAboutBeats("I missed the call, what was decided?"))
        XCTAssertFalse(QuestionIntent.asksAboutBeats("скільки в нас робіт на тижні"))
    }

    func testProjectsAreAskedAboutByWordNotBySubstring() {
        XCTAssertTrue(QuestionIntent.asksAboutProjects("what projects do I have?"))
        XCTAssertTrue(QuestionIntent.asksAboutProjects("which folders am I using"))
        XCTAssertTrue(QuestionIntent.asksAboutProjects("які проєкти в мене є"))
        XCTAssertFalse(QuestionIntent.asksAboutProjects("can you project the numbers forward"))
    }

    func testTasksCatchThePhrasingPeopleActuallyUse() {
        XCTAssertTrue(QuestionIntent.asksAboutTasks("what's on me today"))
        XCTAssertTrue(QuestionIntent.asksAboutTasks("what's on my plate"))
        XCTAssertTrue(QuestionIntent.asksAboutTasks("what's waiting on me"))
        XCTAssertTrue(QuestionIntent.asksAboutTasks("що там на мені"))
    }
}

extension BeatIntentTests {
    /// The feature's new name has to reach the same context the old one did,
    /// without the singular dragging in every letting and support agent a
    /// session ever mentions.
    func testAsksAboutAgents() {
        XCTAssertTrue(QuestionIntent.asksAboutBeats("which agents do I have?"))
        XCTAssertTrue(QuestionIntent.asksAboutBeats("what did my agents find this morning?"))
        XCTAssertTrue(QuestionIntent.asksAboutBeats("які в мене агенти?"))
        XCTAssertTrue(QuestionIntent.asksAboutBeats("покажи звіти по агентах"))
        XCTAssertFalse(QuestionIntent.asksAboutBeats("what did the agent say about the closing date?"))
        XCTAssertFalse(QuestionIntent.asksAboutBeats("the agency sent over the brief"))
    }
}
