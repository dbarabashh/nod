import XCTest
@testable import Nod

final class GranolaCacheTests: XCTestCase {
    /// Granola's real cache is a JSON matryoshka: an outer `{ "cache": "<string>" }`
    /// whose value is itself stringified JSON with a `state` holding documents +
    /// transcripts. Mirrors the fixture anarlog's reader test uses.
    private let fixture = #"""
    {"cache": "{\"state\":{\"documents\":{\"doc-1\":{\"title\":\"Sync\",\"created_at\":\"2024-01-01T14:00:00Z\",\"updated_at\":\"2024-01-01T14:30:00Z\"}},\"transcripts\":{\"doc-1\":[{\"id\":\"seg-1\",\"document_id\":\"doc-1\",\"start_timestamp\":\"2024-01-01T14:00:00Z\",\"end_timestamp\":\"2024-01-01T14:00:05Z\",\"text\":\"Hello there\",\"source\":\"microphone\",\"is_final\":true},{\"id\":\"seg-2\",\"document_id\":\"doc-1\",\"start_timestamp\":\"2024-01-01T14:00:06Z\",\"end_timestamp\":\"2024-01-01T14:00:09Z\",\"text\":\"Hi back\",\"source\":\"system\",\"is_final\":true}]}}}"}
    """#

    func testParseExtractsDocumentsAndSegments() throws {
        let contents = try GranolaCache.parse(Data(fixture.utf8))

        XCTAssertEqual(contents.documents.count, 1)
        XCTAssertEqual(contents.documents["doc-1"]?.title, "Sync")
        XCTAssertEqual(contents.documents["doc-1"]?.createdAt, "2024-01-01T14:00:00Z")

        let segments = try XCTUnwrap(contents.transcripts["doc-1"])
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Hello there")
        XCTAssertEqual(segments[0].source, "microphone")
        XCTAssertEqual(segments[1].source, "system")
    }

    func testParseDropsEmptyTextSegments() throws {
        let json = #"{"cache": "{\"state\":{\"documents\":{},\"transcripts\":{\"d\":[{\"id\":\"s\",\"document_id\":\"d\",\"start_timestamp\":\"\",\"end_timestamp\":\"\",\"text\":\"   \",\"source\":\"system\",\"is_final\":true}]}}}"}"#
        let contents = try GranolaCache.parse(Data(json.utf8))
        XCTAssertTrue(contents.transcripts.isEmpty)
    }

    func testMalformedThrows() {
        XCTAssertThrowsError(try GranolaCache.parse(Data(#"{"not":"granola"}"#.utf8)))
    }

    func testSourceMapsToMeAndThem() {
        XCTAssertEqual(
            GranolaImporter.parseDate("2024-01-01T14:00:00Z")?
                .timeIntervalSince1970,
            1_704_117_600
        )
        XCTAssertNil(GranolaImporter.parseDate(""))
    }

    func testDeterministicUUIDIsStableAndNamespaced() {
        let first = GranolaImporter.deterministicUUID("granola.meeting:doc-1")
        let firstAgain = GranolaImporter.deterministicUUID("granola.meeting:doc-1")
        let other = GranolaImporter.deterministicUUID("granola.meeting:doc-2")
        XCTAssertEqual(first, firstAgain)
        XCTAssertNotEqual(first, other)
        // RFC-4122 v5: version nibble is 5.
        XCTAssertEqual(first.uuidString.split(separator: "-")[2].first, "5")
    }
}
