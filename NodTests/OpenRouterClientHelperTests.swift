import XCTest
@testable import Nod

@MainActor
final class ExtractJSONTests: XCTestCase {
    func testBareObjectPassesThrough() {
        XCTAssertEqual(OpenRouterClient.extractJSON("{\"a\":1}"), "{\"a\":1}")
    }

    func testFencedObjectIsUnwrapped() {
        XCTAssertEqual(
            OpenRouterClient.extractJSON("```json\n{\"a\":1}\n```"),
            "{\"a\":1}"
        )
    }

    func testUppercaseLanguageHintIsTolerated() {
        XCTAssertEqual(
            OpenRouterClient.extractJSON("```JSON\n{\"a\":1}\n```"),
            "{\"a\":1}"
        )
    }

    func testTrailingProseAfterFenceIsDropped() {
        let raw = "```json\n{\"verdict\":\"ok\"}\n```\nThe transcript is too vague to say more."
        XCTAssertEqual(OpenRouterClient.extractJSON(raw), "{\"verdict\":\"ok\"}")
    }

    func testLeadingProseIsNarrowedToObject() {
        XCTAssertEqual(
            OpenRouterClient.extractJSON("Here is the result: {\"a\": 1} hope that helps"),
            "{\"a\": 1}"
        )
    }

    func testArrayPayloadIsSupported() {
        XCTAssertEqual(OpenRouterClient.extractJSON("[1, 2, 3]"), "[1, 2, 3]")
    }

    func testGarbagePassesThroughTrimmed() {
        XCTAssertEqual(OpenRouterClient.extractJSON("  no json at all \n"), "no json at all")
    }
}

@MainActor
final class RetryClassificationTests: XCTestCase {
    func testTransientStatuses() {
        XCTAssertTrue(OpenRouterClient.isTransient(.requestFailed(status: 429, body: "")))
        XCTAssertTrue(OpenRouterClient.isTransient(.requestFailed(status: 500, body: "")))
        XCTAssertTrue(OpenRouterClient.isTransient(.requestFailed(status: 546, body: "")))
        XCTAssertTrue(OpenRouterClient.isTransient(.networkFailed(URLError(.timedOut))))
    }

    func testPermanentFailures() {
        XCTAssertFalse(OpenRouterClient.isTransient(.requestFailed(status: 400, body: "")))
        XCTAssertFalse(OpenRouterClient.isTransient(.requestFailed(status: 404, body: "")))
        XCTAssertFalse(OpenRouterClient.isTransient(.unauthenticated))
        XCTAssertFalse(OpenRouterClient.isTransient(.updateRequired))
        XCTAssertFalse(OpenRouterClient.isTransient(.deviceConflict))
        XCTAssertFalse(OpenRouterClient.isTransient(.emptyResponse))
        XCTAssertFalse(OpenRouterClient.isTransient(.decodingFailed("x")))
    }

    func testRateLimitedStatusesGetLongerBackoffBase() {
        let rateLimited = OpenRouterClient.ClientError.requestFailed(status: 429, body: "")
        XCTAssertEqual(OpenRouterClient.retryDelayMillis(for: rateLimited, attempt: 0), 800)
        XCTAssertEqual(OpenRouterClient.retryDelayMillis(for: rateLimited, attempt: 1), 1600)
        XCTAssertEqual(OpenRouterClient.retryDelayMillis(for: rateLimited, attempt: 2), 3200)

        let workerLimit = OpenRouterClient.ClientError.requestFailed(status: 546, body: "")
        XCTAssertEqual(OpenRouterClient.retryDelayMillis(for: workerLimit, attempt: 0), 800)
    }

    func testOtherTransientsGetShortBackoffBase() {
        let serverError = OpenRouterClient.ClientError.requestFailed(status: 500, body: "")
        XCTAssertEqual(OpenRouterClient.retryDelayMillis(for: serverError, attempt: 0), 400)
        XCTAssertEqual(OpenRouterClient.retryDelayMillis(for: serverError, attempt: 1), 800)

        let network = OpenRouterClient.ClientError.networkFailed(URLError(.timedOut))
        XCTAssertEqual(OpenRouterClient.retryDelayMillis(for: network, attempt: 2), 1600)
    }
}

@MainActor
final class SanitizeErrorBodyTests: XCTestCase {
    func testHTMLPageWithTitleIsReducedToTitle() {
        let html = "<html><head><title>502 Bad Gateway</title></head><body>nginx</body></html>"
        XCTAssertEqual(
            OpenRouterClient.sanitizeErrorBody(html),
            "HTML error page: 502 Bad Gateway"
        )
    }

    func testHTMLPageWithoutTitleGetsGenericLabel() {
        let html = "<!DOCTYPE html><html><body>nope</body></html>"
        XCTAssertEqual(
            OpenRouterClient.sanitizeErrorBody(html),
            "HTML error page (likely wrong endpoint or auth issue)"
        )
    }

    func testProxyStringErrorIsExtracted() {
        XCTAssertEqual(
            OpenRouterClient.sanitizeErrorBody("{\"error\": \"quota exceeded\"}"),
            "quota exceeded"
        )
    }

    func testOpenRouterErrorObjectIncludesProviderHint() {
        let body = """
        {"error": {"message": "Rate limit exceeded", "metadata": {"provider_name": "Google AI Studio"}}}
        """
        XCTAssertEqual(
            OpenRouterClient.sanitizeErrorBody(body),
            "Rate limit exceeded (via Google AI Studio)"
        )
    }

    func testPlainTextPassesThrough() {
        XCTAssertEqual(OpenRouterClient.sanitizeErrorBody("  boom \n"), "boom")
    }

    func testLongBodyIsCapped() {
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(OpenRouterClient.sanitizeErrorBody(long).count, 240)
    }
}
