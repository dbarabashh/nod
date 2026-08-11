import XCTest
@testable import Nod

/// `title` used to have no model of its own — it inherited `model`
/// (summary/recap's default) with no way to move one without the other.
/// This is the regression test the OpenRouter migration plan's PR 1 calls
/// for: a summary-model override must never leak into the title model.
@MainActor
final class LLMProxyClientModelRoutingTests: XCTestCase {
    private let modelKey = "openrouter.model"
    private let titleModelKey = "openrouter.model.title"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: modelKey)
        UserDefaults.standard.removeObject(forKey: titleModelKey)
        super.tearDown()
    }

    func testTitleModelIsIndependentOfSummaryModelOverride() {
        let client = LLMProxyClient()
        let defaultTitleModel = client.titleModel

        UserDefaults.standard.set("google/gemini-2.5-pro", forKey: modelKey)

        XCTAssertEqual(client.model, "google/gemini-2.5-pro")
        XCTAssertEqual(client.titleModel, defaultTitleModel, "changing the summary model must not move title")
    }

    func testTitleModelHasItsOwnOverride() {
        let client = LLMProxyClient()
        UserDefaults.standard.set("openai/gpt-5-mini", forKey: titleModelKey)

        XCTAssertEqual(client.titleModel, "openai/gpt-5-mini")
        XCTAssertNotEqual(client.model, client.titleModel)
    }
}
