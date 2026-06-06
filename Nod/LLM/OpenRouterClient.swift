import Foundation
import Supabase

/// Client for the `llm-proxy` Supabase Edge Function (issue #11).
///
/// All LLM traffic — chat completions + Whisper transcription — flows
/// through `<supabase-project>/functions/v1/llm-proxy`. Authentication is
/// the user's Supabase JWT; the OpenRouter API key lives in the server-side
/// `OPENROUTER_API_KEY` secret and never reaches the client binary.
@MainActor
final class OpenRouterClient: ObservableObject {
    enum ClientError: LocalizedError {
        case unauthenticated
        case updateRequired
        case requestFailed(status: Int, body: String)
        case emptyResponse
        case decodingFailed(String)
        case networkFailed(Error)

        var errorDescription: String? {
            switch self {
            case .unauthenticated:
                "Session expired, please sign in again."
            case .updateRequired:
                "This version of Nod is out of date. Please update to continue."
            case let .requestFailed(status, body):
                "LLM proxy HTTP \(status): \(body)"
            case .emptyResponse:
                "LLM proxy returned an empty response."
            case let .decodingFailed(detail):
                "Failed to decode proxy response: \(detail)"
            case let .networkFailed(error):
                "Network error: \(error.localizedDescription)"
            }
        }
    }

    /// Chat model override — kept in UserDefaults so devs can A/B models
    /// without rebuilding. Default points at Gemini 2.0 Flash via OpenRouter.
    var model: String {
        UserDefaults.standard.string(forKey: "openrouter.model") ?? "google/gemini-2.0-flash-001"
    }

    /// Cross-provider fallback used when the primary model is unavailable
    /// (429 from a shared-quota provider, upstream 5xx, etc.). Claude Haiku
    /// 4.5 is the chosen default: high-quality output that still tolerates
    /// our strict JSON-mode prompts, served from Anthropic's own infra so
    /// it doesn't share Google's per-minute free-tier quota that was
    /// triggering the 429s on `gemini-2.0-flash-001 (via Google AI Studio)`.
    /// Override via `defaults write com.example.nod openrouter.model.fallback "..."`.
    var fallbackModel: String {
        UserDefaults.standard.string(forKey: "openrouter.model.fallback") ?? "anthropic/claude-haiku-4.5"
    }

    /// Whisper model override — same rationale as above. `large-v3-turbo` is
    /// the distilled 4-decoder-layer variant of `large-v3`: ~8× faster decode,
    /// near-identical WER for the languages we care about, and meaningfully
    /// cheaper per minute. Override with `defaults write com.example.nod
    /// whisper.model "openai/whisper-large-v3"` to A/B against full v3, or
    /// `"openai/whisper-1"` if a route drops the v3 family.
    private var whisperModel: String {
        UserDefaults.standard.string(forKey: "whisper.model") ?? "openai/whisper-large-v3-turbo"
    }

    private let proxyURL: URL
    private let supabase: SupabaseClient?
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 70 // proxy enforces 60s for transcribe; give it slack
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    init(supabase: SupabaseClient? = nil) {
        self.supabase = supabase
        proxyURL = SupabaseConfig.url.appendingPathComponent("functions/v1/llm-proxy")
    }

    // MARK: - Chat completion

    /// One turn in a multi-message conversation. `system` is supplied
    /// separately to `chat`; these are the alternating user/assistant turns.
    struct ChatTurn: Equatable {
        enum Role: String { case user, assistant }
        let role: Role
        let content: String

        init(role: Role, content: String) {
            self.role = role
            self.content = content
        }
    }

    func complete(system: String, user: String, jsonMode: Bool = false) async throws -> String {
        let userPreview = String(user.prefix(200))
        Log.llm.info(
            "→ chat via proxy model=\(model) fallback=\(fallbackModel) system.len=\(system.count) user.len=\(user.count) jsonMode=\(jsonMode)"
        )
        Log.llm.info("→ user preview: \(userPreview)\(user.count > 200 ? "…" : "")")

        return try await send(
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user)
            ],
            jsonMode: jsonMode
        )
    }

    /// Multi-turn chat: a system prompt followed by the running
    /// user/assistant history. Used by single-session chat (step 3). The
    /// transcript + recap live in `system`; `history` is just the dialogue.
    func chat(system: String, history: [ChatTurn], temperature: Double? = nil) async throws -> String {
        Log.llm.info("→ multi-turn chat via proxy model=\(model) system.len=\(system.count) turns=\(history.count)")
        var messages: [ChatRequest.Message] = [.init(role: "system", content: system)]
        messages += history.map { .init(role: $0.role.rawValue, content: $0.content) }
        return try await send(messages: messages, jsonMode: false, temperature: temperature)
    }

    /// Shared transport for every chat call. Applies the same provider
    /// routing + model fallback chain used across the app (see the strategy
    /// note below) and decodes the assistant message.
    private func send(messages: [ChatRequest.Message], jsonMode: Bool, temperature: Double? = nil) async throws -> String {
        // Routing strategy:
        //
        // `provider.order = ["google-vertex"]` + `ignore = ["google-ai-studio"]`
        // forces OpenRouter to skip Google's shared free-tier endpoint (the one
        // returning 429 "Provider returned error (via Google AI Studio)" in our
        // logs) and use the paid Vertex route instead. Vertex bills against
        // our OpenRouter credits but has per-second, not per-minute-shared,
        // limits — so concurrent taps stop racing other OpenRouter customers
        // for the same free bucket. For non-Google primary models these hints
        // are no-ops; OpenRouter ignores irrelevant entries.
        //
        // `models = [primary, fallback]` is the model-level retry chain. If
        // the primary fails for ANY reason (provider outage, 429 on every
        // route, content policy block), OpenRouter retries with the fallback
        // automatically — same response shape, transparent to the client.
        let payload = ChatRequest(
            model: model,
            models: [model, fallbackModel],
            messages: messages,
            provider: ProviderPreference(
                order: ["google-vertex"],
                ignore: ["google-ai-studio"],
                allow_fallbacks: true
            ),
            response_format: jsonMode ? ResponseFormat(type: "json_object") : nil,
            temperature: temperature
        )
        let body = try JSONEncoder().encode(ProxyEnvelope(kind: "chat", payload: payload))

        do {
            let data = try await postToProxyWithRetry(body: body)
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
                Log.llm.error("empty content")
                throw ClientError.emptyResponse
            }
            let preview = String(text.prefix(200))
            Log.llm.info("← OK len=\(text.count) preview: \(preview)\(text.count > 200 ? "…" : "")")
            return text
        } catch let error as ClientError {
            throw error
        } catch {
            // JSONDecoder threw something non-ClientError — surface as
            // decoding failure (deterministic, not retried).
            throw ClientError.decodingFailed(error.localizedDescription)
        }
    }

    /// JSON-mode chat call: requests `response_format = json_object` from the
    /// model and decodes the assistant message into `T`. Some upstream models
    /// still wrap valid JSON in stray fences and/or pad it with prose; we
    /// extract the JSON value before decoding so a well-shaped payload survives
    /// a sloppy model. A genuinely malformed response surfaces as
    /// `.decodingFailed`.
    func completeJSON<T: Decodable>(system: String, user: String, as type: T.Type) async throws -> T {
        let raw = try await complete(system: system, user: user, jsonMode: true)
        let cleaned = Self.extractJSON(raw)
        guard let data = cleaned.data(using: .utf8) else {
            throw ClientError.decodingFailed("non-utf8 LLM response")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Log.llm.error("JSON decode failed: \(error.localizedDescription) — body[0..200]=\(String(cleaned.prefix(200)))")
            throw ClientError.decodingFailed(error.localizedDescription)
        }
    }

    /// Pulls the JSON value out of a model response that may be fenced and/or
    /// padded with prose. Handles the shapes seen in the wild: a bare object, a
    /// fenced object, and — the one that used to break decoding — a fenced
    /// object followed by an explanatory paragraph (e.g. Gemini appending "The
    /// transcript is too vague…" *after* the closing ```). Drops the fence
    /// (everything from the closing ``` onward), then narrows to the outermost
    /// `{…}` / `[…]` so leading or trailing prose can't reach the decoder.
    private static func extractJSON(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t.removeFirst(3)
            // Tolerate any case of the "json" language hint (some emit ```JSON).
            if t.lowercased().hasPrefix("json") { t.removeFirst(4) }
            if let fence = t.range(of: "```") {
                t = String(t[t.startIndex ..< fence.lowerBound])
            }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = t.firstIndex(where: { $0 == "{" || $0 == "[" }) {
            let close: Character = t[start] == "{" ? "}" : "]"
            if let end = t.lastIndex(of: close), end > start {
                return String(t[start ... end])
            }
        }
        return t
    }

    /// True for errors that are plausibly fixed by a retry: upstream 5xx
    /// (provider hiccups), 429 (rate limits — time-bucketed, usually clear
    /// within seconds), and URLError-class transport blips. Excludes 4xx
    /// (other than 429), decoding errors, empty responses, and auth failures.
    private static func isTransient(_ error: ClientError) -> Bool {
        switch error {
        case let .requestFailed(status, _):
            status == 429 || (status >= 500 && status < 600)
        case .networkFailed:
            true
        case .unauthenticated, .updateRequired, .emptyResponse, .decodingFailed:
            false
        }
    }

    /// Exponential backoff in milliseconds. 429 gets a longer base because
    /// rate limits are time-bucketed — burning a 200ms retry the moment a
    /// 429 lands almost always re-trips the same bucket. 546 (Edge Function
    /// WORKER_RESOURCE_LIMIT) gets the same treatment: the killed worker is
    /// still hot, so a fast retry just re-hits the same wall — backing off lets
    /// the platform route to a fresh instance. 5xx / network blips retry sooner
    /// since they're usually fixed by the next request.
    private static func retryDelayMillis(for error: ClientError, attempt: Int) -> UInt64 {
        let base: UInt64 = switch error {
        case let .requestFailed(status, _) where status == 429 || status == 546:
            800
        default:
            400
        }
        return base * UInt64(1 << attempt) // 0→base, 1→2×base, 2→4×base
    }

    // MARK: - Whisper (audio transcription)

    /// Sends an audio blob to the proxy's transcribe route. The proxy forwards
    /// to OpenRouter's `/api/v1/audio/transcriptions`, which expects a JSON
    /// body with base64-encoded audio (NOT multipart — sending multipart to
    /// OpenRouter's handler returns a generic 500).
    func transcribe(audio: Data, fileName: String = "audio.wav", language: String = "en") async throws -> String {
        let inner = TranscriptionRequest(
            model: whisperModel,
            input_audio: .init(data: audio.base64EncodedString(), format: "wav"),
            language: language
        )
        let bodyData = try JSONEncoder().encode(ProxyEnvelope(kind: "transcribe", payload: inner))

        Log.llm.info("→ transcribe via proxy model=\(whisperModel) audio_bytes=\(audio.count) body_bytes=\(bodyData.count) lang=\(language)")

        let data = try await postToProxyWithRetry(body: bodyData)
        do {
            let decoded = try JSONDecoder().decode(WhisperResponse.self, from: data)
            let text = decoded.text ?? ""
            Log.llm.info("← Whisper OK len=\(text.count)")
            return text
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            let sanitized = Self.sanitizeErrorBody(body)
            Log.llm.error("Whisper decode failed: \(error.localizedDescription) body=\(sanitized)")
            throw ClientError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Cross-session knowledge (step 5)

    /// Embedding ~1200-char chunks is CPU-heavy server-side; gte-small runs
    /// in-process in the Edge runtime, so each chunk in a batch is a sequential
    /// inference on the same invocation. At 4/call the worker still trips its
    /// CPU budget (WORKER_RESOURCE_LIMIT / HTTP 546), especially when the call
    /// collides with the recap/title/entity burst at meeting end. Keep it small.
    private static let indexBatchSize = 2

    /// Indexes a session's transcript chunks for cross-session search. The
    /// proxy embeds each chunk server-side (gte-small) and writes the vectors —
    /// the client only ships the text, in small sequential batches so no single
    /// invocation embeds enough to exceed the worker CPU budget.
    func indexSession(meetingID: UUID, chunks: [String]) async throws {
        struct Payload: Encodable {
            let meeting_id: UUID
            let chunks: [String]
            let base_idx: Int
            let total: Int
        }
        let total = chunks.count
        guard total > 0 else { return }
        Log.llm.info("→ index via proxy meeting=\(meetingID.uuidString) chunks=\(total) batch=\(Self.indexBatchSize)")
        var base = 0
        while base < total {
            let upper = min(base + Self.indexBatchSize, total)
            let payload = Payload(meeting_id: meetingID, chunks: Array(chunks[base ..< upper]), base_idx: base, total: total)
            let body = try JSONEncoder().encode(ProxyEnvelope(kind: "index", payload: payload))
            _ = try await postToProxyWithRetry(body: body)
            base = upper
        }
    }

    /// Pre-retrieval query transform shared by single- and cross-session
    /// chat. Produces a self-contained query (pronouns/ellipsis resolved
    /// against `history`) and a hypothetical transcript-style answer to embed
    /// for retrieval (HyDE). Fails open: any error yields the raw query and no
    /// HyDE doc, so a failure degrades to plain query-embedding rather than
    /// breaking search.
    func prepareSearchQuery(
        history: [ChatTurn],
        query: String,
        language: AppLanguage = .english,
        personalContext: String = ""
    ) async -> (standalone: String, hyde: String?) {
        struct HyDEResult: Decodable {
            let standalone_query: String
            let hypothetical_answer: String
        }
        let (system, user) = PromptLibrary.buildHyDE(
            history: history,
            query: query,
            language: language,
            personalContext: personalContext
        )
        do {
            let result = try await completeJSON(system: system, user: user, as: HyDEResult.self)
            let standalone = result.standalone_query.trimmingCharacters(in: .whitespacesAndNewlines)
            let hyde = result.hypothetical_answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return (standalone.isEmpty ? query : standalone, hyde.isEmpty ? nil : hyde)
        } catch {
            Log.llm.error("query prep failed (using raw query): \(error.localizedDescription)")
            return (query, nil)
        }
    }

    /// Semantic search over the user's chunks. `meetingID` narrows to one
    /// session (used to retrieve relevant parts of a long meeting instead of
    /// stuffing its whole transcript); `meetingIDs` narrows to a set (label
    /// scope) while keeping the cross-session entity boost; nil/nil searches
    /// across all sessions.
    func searchKnowledge(
        query: String,
        matchCount: Int = 8,
        meetingID: UUID? = nil,
        meetingIDs: [UUID]? = nil,
        embedText: String? = nil
    ) async throws -> [RetrievedChunk] {
        struct Payload: Encodable {
            let query: String
            let match_count: Int
            let meeting_id: String?
            let meeting_ids: [String]?
            let embed_text: String?
        }
        Log.llm.info(
            "→ search via proxy q.len=\(query.count) scoped=\(meetingID != nil) labelScoped=\(meetingIDs != nil) hyde=\(embedText != nil)"
        )
        let payload = Payload(
            query: query,
            match_count: matchCount,
            meeting_id: meetingID?.uuidString,
            meeting_ids: meetingIDs?.map(\.uuidString),
            embed_text: embedText
        )
        let body = try JSONEncoder().encode(ProxyEnvelope(kind: "search", payload: payload))
        let data = try await postToProxyWithRetry(body: body)
        struct Wrapper: Decodable { let matches: [RetrievedChunk] }
        do {
            return try JSONDecoder().decode(Wrapper.self, from: data).matches
        } catch {
            throw ClientError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Transport

    /// Wraps `postToProxy` with exponential-backoff retries on transient
    /// errors (5xx, 429, URLError). 429s in particular were dropping ~30% of
    /// Whisper chunks on the OpenRouter free tier, which is what made the
    /// "Suggest reply" answers go stale mid-meeting.
    private func postToProxyWithRetry(body: Data) async throws -> Data {
        let maxAttempts = 3
        var lastError: ClientError = .emptyResponse
        for attempt in 0 ..< maxAttempts {
            do {
                return try await postToProxy(body: body)
            } catch let error as ClientError {
                lastError = error
                let isLastAttempt = attempt == maxAttempts - 1
                if !isLastAttempt, Self.isTransient(error) {
                    let delayMs = Self.retryDelayMillis(for: error, attempt: attempt)
                    Log.llm.error(
                        "transient error on attempt \(attempt + 1)/\(maxAttempts) — retrying in \(delayMs)ms: \(error.localizedDescription)"
                    )
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    continue
                }
                throw error
            }
        }
        throw lastError
    }

    private func postToProxy(body: Data) async throws -> Data {
        guard let supabase else {
            Log.llm.error("no Supabase client — request blocked")
            throw ClientError.unauthenticated
        }

        // Use the async session accessor — it transparently refreshes the
        // JWT when the cached token is expired. The previous sync read of
        // `currentSession?.accessToken` would happily send a stale token
        // while the SDK's background refresh was in flight → proxy 401 →
        // user sees "Session expired" mid-meeting even though a valid
        // refreshed token landed milliseconds later. Real-world impact:
        // a long recording crosses the 1h JWT TTL and the summary or a
        // chunk transcription falls off a cliff.
        let jwt: String
        do {
            jwt = try await supabase.auth.session.accessToken
        } catch let urlError as URLError {
            // Network blip during the SDK's refresh round-trip — treat as
            // transient so the retry loop has a chance to re-fire after
            // connectivity returns. Without this, a 200ms Wi-Fi dropout
            // mid-meeting turns into a permanent "Session expired" nag.
            Log.llm.error("auth.session refresh: transient network error \(urlError.code.rawValue) — \(urlError.localizedDescription)")
            throw ClientError.networkFailed(urlError)
        } catch {
            // Anything else (refresh token revoked, malformed session,
            // unrecoverable SDK error) → genuine sign-out path.
            Log.llm.error("auth.session refresh failed: \(error.localizedDescription)")
            throw ClientError.unauthenticated
        }

        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        // Lets the proxy enforce the minimum build (426) and stamp the user's
        // version into their profile row for support/visibility.
        request.setValue(String(AppVersion.build), forHTTPHeaderField: "x-app-build")
        request.setValue(AppVersion.version, forHTTPHeaderField: "x-app-version")
        request.setValue(AppVersion.osVersion, forHTTPHeaderField: "x-os-version")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // URLError (offline, DNS, timeout, host unreachable, …) lands here.
            // Surface it as a distinct case so the chat retry loop can treat
            // it as transient and the user sees a "Network error" message
            // instead of a misleading "Failed to decode" one.
            Log.llm.error("proxy transport error: \(error.localizedDescription)")
            throw ClientError.networkFailed(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.decodingFailed("Non-HTTP response")
        }
        if http.statusCode == 401 {
            throw ClientError.unauthenticated
        }
        if http.statusCode == 426 {
            // Proxy rejected a build below `minimum_build`. Flip the gate so
            // the update screen shows even if the launch check was skipped.
            NotificationCenter.default.post(name: .nodUpdateRequired, object: nil)
            throw ClientError.updateRequired
        }
        if http.statusCode >= 400 {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            let sanitized = Self.sanitizeErrorBody(raw)
            Log.llm.error("proxy HTTP \(http.statusCode): \(sanitized)")
            throw ClientError.requestFailed(status: http.statusCode, body: sanitized)
        }
        return data
    }

    /// Reduce arbitrary error response bodies (HTML pages, giant JSON with
    /// nested metadata, etc.) to something short and human-readable so they
    /// don't flood log/UI.
    private static func sanitizeErrorBody(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        if lowered.hasPrefix("<!doctype") || lowered.hasPrefix("<html") {
            if let titleOpen = lowered.range(of: "<title"),
               let titleClose = lowered.range(of: "</title>"),
               titleOpen.upperBound < titleClose.lowerBound {
                let slice = trimmed[titleOpen.upperBound ..< titleClose.lowerBound]
                if let gt = slice.firstIndex(of: ">") {
                    let title = slice[slice.index(after: gt)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        return "HTML error page: \(String(title.prefix(160)))"
                    }
                }
            }
            return "HTML error page (likely wrong endpoint or auth issue)"
        }

        if let data = trimmed.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = parsed["error"] {
            // Proxy returns `{ "error": "..." }` (string) while OpenRouter
            // upstream errors look like `{ "error": { "message": "..." } }`.
            if let errString = err as? String { return String(errString.prefix(220)) }
            if let errObj = err as? [String: Any] {
                let message = (errObj["message"] as? String) ?? ""
                var providerHint = ""
                if let metadata = errObj["metadata"] as? [String: Any],
                   let provider = metadata["provider_name"] as? String {
                    providerHint = " (via \(provider))"
                }
                if !message.isEmpty {
                    return String(message.prefix(220)) + providerHint
                }
            }
        }

        return String(trimmed.prefix(240))
    }
}

// MARK: - Wire types

private struct ProxyEnvelope<Payload: Encodable>: Encodable {
    let kind: String
    let payload: Payload
}

private struct TranscriptionRequest: Encodable {
    struct InputAudio: Encodable {
        let data: String
        let format: String
    }

    let model: String
    let input_audio: InputAudio
    let language: String?
}

private struct WhisperResponse: Decodable {
    let text: String?
}

private struct ChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let models: [String]?
    let messages: [Message]
    let provider: ProviderPreference?
    let response_format: ResponseFormat?
    let temperature: Double?
}

private struct ResponseFormat: Encodable {
    let type: String
}

private struct ProviderPreference: Encodable {
    let order: [String]?
    let ignore: [String]?
    let allow_fallbacks: Bool?
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }

    let choices: [Choice]
}
