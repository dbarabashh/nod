import XCTest
@testable import Nod

/// What a beat may read travels as provider slugs. A slug this build has never
/// heard of must not take the whole beat down with it.
final class BeatProvidersTests: XCTestCase {
    private func decode(_ providers: String) throws -> Beat {
        let json = """
        {"id":"00000000-0000-4000-8000-000000000001","user_id":"00000000-0000-4000-8000-000000000002",
         "title":"t","prompt":"p","cadence":"daily","hour":9,"minute":0,"weekday":1,"day_of_month":1,
         "timezone":"UTC","enabled":true,"providers":\(providers)}
        """
        return try JSONDecoder().decode(Beat.self, from: Data(json.utf8))
    }

    func testNullMeansEveryConnectedProduct() throws {
        XCTAssertNil(try decode("null").providers)
    }

    func testAnEmptyListMeansNone() throws {
        XCTAssertEqual(try decode("[]").providers, [])
    }

    func testAnUnknownSlugIsDroppedNotFatal() throws {
        XCTAssertEqual(try decode("[\"gmail\",\"hologram\",\"google-calendar\"]").providers, [.gmail, .googleCalendar])
    }

    func testTheChoiceRoundTripsThroughTheInsertPayload() throws {
        let beat = try decode("[\"slack\"]")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(beat)) as? [String: Any]
        XCTAssertEqual(encoded?["providers"] as? [String], ["slack"])
    }

    /// Going back to "every product" has to reach the row as an explicit
    /// null, or the update leaves the old narrowing in place.
    func testClearingTheChoiceSendsNull() throws {
        let beat = try decode("null")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(beat)) as? [String: Any]
        XCTAssertTrue(encoded?["providers"] is NSNull)
    }
}

/// The narrowing reaches the model as the tool catalogue it is offered.
final class BeatToolOfferTests: XCTestCase {
    private func tool(_ provider: IntegrationProvider, _ name: String, mutating: Bool = false) -> ChatTool {
        ChatTool(
            provider: provider,
            name: "\(provider.rawValue)_\(name)",
            description: "",
            parameters: ChatToolSchema(properties: [:], required: []),
            mutating: mutating
        )
    }

    private var catalogue: [ChatTool] {
        [tool(.gmail, "search_messages"), tool(.linear, "search_issues"), tool(.linear, "create_issue", mutating: true)]
    }

    func testNilIsEveryProduct() {
        XCTAssertEqual(KnowledgeChatStore.offered(catalogue, products: nil, readsOnly: false).count, 3)
    }

    func testEmptyIsNoProduct() {
        XCTAssertEqual(KnowledgeChatStore.offered(catalogue, products: [], readsOnly: false), [])
    }

    func testANarrowedBeatSeesOnlyItsProductsAndOnlyReads() {
        let offered = KnowledgeChatStore.offered(catalogue, products: [.linear], readsOnly: true)
        XCTAssertEqual(offered.map(\.action), ["search_issues"])
    }
}
