import XCTest
@testable import Nod

@MainActor
final class ExtractJSONTests: XCTestCase {
    func testBareObjectPassesThrough() {
        XCTAssertEqual(LLMProxyClient.extractJSON("{\"a\":1}"), "{\"a\":1}")
    }

    func testFencedObjectIsUnwrapped() {
        XCTAssertEqual(
            LLMProxyClient.extractJSON("```json\n{\"a\":1}\n```"),
            "{\"a\":1}"
        )
    }

    func testUppercaseLanguageHintIsTolerated() {
        XCTAssertEqual(
            LLMProxyClient.extractJSON("```JSON\n{\"a\":1}\n```"),
            "{\"a\":1}"
        )
    }

    func testTrailingProseAfterFenceIsDropped() {
        let raw = "```json\n{\"verdict\":\"ok\"}\n```\nThe transcript is too vague to say more."
        XCTAssertEqual(LLMProxyClient.extractJSON(raw), "{\"verdict\":\"ok\"}")
    }

    func testLeadingProseIsNarrowedToObject() {
        XCTAssertEqual(
            LLMProxyClient.extractJSON("Here is the result: {\"a\": 1} hope that helps"),
            "{\"a\": 1}"
        )
    }

    func testArrayPayloadIsSupported() {
        XCTAssertEqual(LLMProxyClient.extractJSON("[1, 2, 3]"), "[1, 2, 3]")
    }

    func testGarbagePassesThroughTrimmed() {
        XCTAssertEqual(LLMProxyClient.extractJSON("  no json at all \n"), "no json at all")
    }
}

@MainActor
final class RetryClassificationTests: XCTestCase {
    func testTransientStatuses() {
        XCTAssertTrue(LLMProxyClient.isTransient(.requestFailed(status: 429, body: "")))
        XCTAssertTrue(LLMProxyClient.isTransient(.requestFailed(status: 500, body: "")))
        XCTAssertTrue(LLMProxyClient.isTransient(.requestFailed(status: 546, body: "")))
        XCTAssertTrue(LLMProxyClient.isTransient(.networkFailed(URLError(.timedOut))))
    }

    func testPermanentFailures() {
        XCTAssertFalse(LLMProxyClient.isTransient(.requestFailed(status: 400, body: "")))
        XCTAssertFalse(LLMProxyClient.isTransient(.requestFailed(status: 404, body: "")))
        XCTAssertFalse(LLMProxyClient.isTransient(.unauthenticated))
        XCTAssertFalse(LLMProxyClient.isTransient(.updateRequired))
        XCTAssertFalse(LLMProxyClient.isTransient(.deviceConflict))
        XCTAssertFalse(LLMProxyClient.isTransient(.entitlementRequired))
        XCTAssertFalse(LLMProxyClient.isTransient(.emptyResponse))
        XCTAssertFalse(LLMProxyClient.isTransient(.decodingFailed("x")))
    }

    func testRateLimitedStatusesGetLongerBackoffBase() {
        let rateLimited = LLMProxyClient.ClientError.requestFailed(status: 429, body: "")
        XCTAssertEqual(LLMProxyClient.retryDelayMillis(for: rateLimited, attempt: 0), 800)
        XCTAssertEqual(LLMProxyClient.retryDelayMillis(for: rateLimited, attempt: 1), 1600)
        XCTAssertEqual(LLMProxyClient.retryDelayMillis(for: rateLimited, attempt: 2), 3200)

        let workerLimit = LLMProxyClient.ClientError.requestFailed(status: 546, body: "")
        XCTAssertEqual(LLMProxyClient.retryDelayMillis(for: workerLimit, attempt: 0), 800)
    }

    func testOtherTransientsGetShortBackoffBase() {
        let serverError = LLMProxyClient.ClientError.requestFailed(status: 500, body: "")
        XCTAssertEqual(LLMProxyClient.retryDelayMillis(for: serverError, attempt: 0), 400)
        XCTAssertEqual(LLMProxyClient.retryDelayMillis(for: serverError, attempt: 1), 800)

        let network = LLMProxyClient.ClientError.networkFailed(URLError(.timedOut))
        XCTAssertEqual(LLMProxyClient.retryDelayMillis(for: network, attempt: 2), 1600)
    }
}

@MainActor
final class TemperatureSupportTests: XCTestCase {
    func testModelsThatDroppedSamplingParamsAreExcluded() {
        for model in [
            "anthropic/claude-sonnet-5",
            "anthropic/claude-opus-4.8",
            "anthropic/claude-opus-4.7",
            "anthropic/claude-fable-5",
            "~anthropic/claude-sonnet-latest"
        ] {
            XCTAssertFalse(LLMProxyClient.acceptsTemperature(model), model)
        }
    }

    func testOlderModelsStillAcceptTemperature() {
        for model in [
            "anthropic/claude-sonnet-4.6",
            "anthropic/claude-haiku-4.5",
            "anthropic/claude-opus-4.6",
            "google/gemini-2.5-pro"
        ] {
            XCTAssertTrue(LLMProxyClient.acceptsTemperature(model), model)
        }
    }
}

@MainActor
final class SanitizeErrorBodyTests: XCTestCase {
    func testHTMLPageWithTitleIsReducedToTitle() {
        let html = "<html><head><title>502 Bad Gateway</title></head><body>nginx</body></html>"
        XCTAssertEqual(
            LLMProxyClient.sanitizeErrorBody(html),
            "HTML error page: 502 Bad Gateway"
        )
    }

    func testHTMLPageWithoutTitleGetsGenericLabel() {
        let html = "<!DOCTYPE html><html><body>nope</body></html>"
        XCTAssertEqual(
            LLMProxyClient.sanitizeErrorBody(html),
            "HTML error page (likely wrong endpoint or auth issue)"
        )
    }

    func testProxyStringErrorIsExtracted() {
        XCTAssertEqual(
            LLMProxyClient.sanitizeErrorBody("{\"error\": \"quota exceeded\"}"),
            "quota exceeded"
        )
    }

    func testOpenRouterErrorObjectIncludesProviderHint() {
        let body = """
        {"error": {"message": "Rate limit exceeded", "metadata": {"provider_name": "Google AI Studio"}}}
        """
        XCTAssertEqual(
            LLMProxyClient.sanitizeErrorBody(body),
            "Rate limit exceeded (via Google AI Studio)"
        )
    }

    func testPlainTextPassesThrough() {
        XCTAssertEqual(LLMProxyClient.sanitizeErrorBody("  boom \n"), "boom")
    }

    func testLongBodyIsCapped() {
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(LLMProxyClient.sanitizeErrorBody(long).count, 240)
    }
}

@MainActor
final class GenerationCostTests: XCTestCase {
    func testSemanticPurposeDoesNotDependOnConfiguredModelNames() {
        XCTAssertEqual(GenerationContext.Purpose.recap.task, "summary")
        for purpose in [GenerationContext.Purpose.speakerNames, .entities, .agentDrafts, .contextualRecall] {
            XCTAssertEqual(purpose.task, "utility")
        }
    }

    func testMeetingMetadataIsOptionalAndUsesWireNames() throws {
        let id = UUID()
        let context = GenerationContext(purpose: .entities, meetingID: id)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as? [String: String])
        XCTAssertEqual(json["purpose"], "entities")
        XCTAssertEqual(json["meeting_id"], id.uuidString)
        let withoutMeeting = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(GenerationContext(purpose: .recap))) as? [String: String]
        )
        XCTAssertNil(withoutMeeting["meeting_id"])
    }

    func testDistillationWaitsAtLeastOneMinuteAndHonorsLongProviderDelay() {
        XCTAssertEqual(LLMProxyClient.distillationRetryAfter(nil), 60)
        XCTAssertEqual(LLMProxyClient.distillationRetryAfter("bad"), 60)
        XCTAssertEqual(LLMProxyClient.distillationRetryAfter("0"), 60)
        XCTAssertEqual(LLMProxyClient.distillationRetryAfter("180"), 180)
        XCTAssertEqual(LLMProxyClient.distillationRetryAfter("90000"), 90000)
    }
}

final class DistillationScheduleTests: XCTestCase {
    func testConcurrentResponsesCannotShortenProviderCooldown() {
        var schedule = DistillationSchedule()
        let now = Date(timeIntervalSince1970: 1000)
        let first = UUID()
        let second = UUID()
        XCTAssertTrue(schedule.begin(first, now: now))
        XCTAssertTrue(schedule.begin(second, now: now))
        schedule.rateLimited(for: 90000, now: now)
        schedule.finish(first)
        schedule.rateLimited(for: 60, now: now.addingTimeInterval(1))
        schedule.finish(second)
        XCTAssertFalse(schedule.begin(UUID(), now: now.addingTimeInterval(61)))
        XCTAssertFalse(schedule.begin(first, now: now.addingTimeInterval(89999)))
        XCTAssertTrue(schedule.begin(first, now: now.addingTimeInterval(90000)))
    }

    func testOverlappingMeetingAndFailedAttemptAreDeferredButOtherMeetingsCanRun() {
        var schedule = DistillationSchedule()
        let now = Date(timeIntervalSince1970: 1000)
        let meeting = UUID()
        XCTAssertTrue(schedule.begin(meeting, now: now))
        XCTAssertFalse(schedule.begin(meeting, now: now))
        schedule.failed(meeting, now: now)
        schedule.finish(meeting)
        XCTAssertFalse(schedule.begin(meeting, now: now.addingTimeInterval(299)))
        XCTAssertTrue(schedule.begin(UUID(), now: now))
        XCTAssertTrue(schedule.begin(meeting, now: now.addingTimeInterval(300)))
        schedule.succeeded(meeting)
        schedule.finish(meeting)
        XCTAssertTrue(schedule.begin(meeting, now: now.addingTimeInterval(301)))
    }
}
