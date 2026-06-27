import Foundation
import Supabase

/// Client for the `llm-proxy` Supabase Edge Function (issue #11).
///
/// All LLM traffic — chat completions + Whisper transcription — flows
/// through `<supabase-project>/functions/v1/llm-proxy`. Authentication is
/// the user's Supabase JWT; the OpenRouter API key lives in the server-side
/// `OPENROUTER_API_KEY` secret and never reaches the client binary.
///
/// `@MainActor` is deliberate even though there are no `@Published` properties:
/// the type is injected as an `@EnvironmentObject` and posts UI-affecting
/// notifications (`.nodDeviceConflict`, `.nodUpdateRequired`,
/// `.nodOpenSubscription`) whose observers run synchronously on the posting
/// thread. Don't drop the isolation to move the per-chunk JSON/base64 work off
/// the main thread without also relocating those side-effects — otherwise they
/// fire on a background thread and race the UI. Profile first; the codec cost
/// is a few ms per chunk and the WAV bytes are already built off-main in
/// `WhisperTranscriber`.
@MainActor
final class LLMProxyClient: ObservableObject {
    enum ClientError: LocalizedError {
        case unauthenticated
        case updateRequired
        case deviceConflict
        case entitlementRequired
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
            case .deviceConflict:
                "This account is already in use on another device."
            case .entitlementRequired:
                "Your plan doesn't cover this. Please choose a plan to continue."
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
    /// without rebuilding. Default is Claude Sonnet 4.6: a reasoning-class model
    /// that reads context, metaphor, and subtext far better than the previous
    /// `gemini-2.0-flash` default, which produced shallow, literal recaps. Pairs
    /// with the Claude Haiku 4.5 fallback below. Override with
    /// `defaults write com.example.nod openrouter.model "google/gemini-2.5-pro"`.
    private static let modelKey = "openrouter.model"
    private static let fallbackModelKey = "openrouter.model.fallback"
    private static let whisperModelKey = "whisper.model"

    var model: String {
        UserDefaults.standard.string(forKey: Self.modelKey) ?? "anthropic/claude-sonnet-4.6"
    }

    /// Cross-provider fallback used when the primary model is unavailable
    /// (429 from a shared-quota provider, upstream 5xx, etc.). Claude Haiku
    /// 4.5 is the chosen default: high-quality output that still tolerates
    /// our strict JSON-mode prompts, served from Anthropic's own infra so
    /// it doesn't share Google's per-minute free-tier quota that was
    /// triggering the 429s on `gemini-2.0-flash-001 (via Google AI Studio)`.
    /// Override via `defaults write com.example.nod openrouter.model.fallback "..."`.
    var fallbackModel: String {
        UserDefaults.standard.string(forKey: Self.fallbackModelKey) ?? "anthropic/claude-haiku-4.5"
    }

    /// Provider routing hints for the chat call. The `google-vertex` pin +
    /// `google-ai-studio` ignore exist solely to dodge Google's shared free-tier
    /// 429s (see the routing note in `send`); they only apply to Google models.
    /// For a non-Google primary (e.g. Claude) those hints would needlessly
    /// constrain routing — Claude is also served via Vertex on OpenRouter, so
    /// pinning the order there would silence Anthropic's own infra — so we send
    /// no order/ignore and let OpenRouter pick the best provider.
    private var providerPreference: ProviderPreference {
        guard model.hasPrefix("google/") else {
            return ProviderPreference(order: nil, ignore: nil, allow_fallbacks: true)
        }
        return ProviderPreference(order: ["google-vertex"], ignore: ["google-ai-studio"], allow_fallbacks: true)
    }

    /// Whisper model override — same rationale as above. Default is full
    /// `large-v3`: meaningfully better WER on code-switched (uk/ru/en surzhik)
    /// speech than the distilled `large-v3-turbo`, where the missing decoder
    /// layers produced phonetic hallucinations on mixed-language audio. On Groq
    /// (the primary STT provider) both run on the same LPU, so full v3 costs
    /// almost no extra latency. Override with `defaults write com.example.nod
    /// whisper.model "openai/whisper-large-v3-turbo"` to A/B against turbo, or
    /// `"openai/whisper-1"` if a route drops the v3 family.
    private var whisperModel: String {
        UserDefaults.standard.string(forKey: Self.whisperModelKey) ?? "openai/whisper-large-v3"
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
    }

    func complete(system: String, user: String, jsonMode: Bool = false) async throws -> String {
        Log.llm.info(
            "→ chat via proxy model=\(model) fallback=\(fallbackModel) system.len=\(system.count) user.len=\(user.count) jsonMode=\(jsonMode)"
        )
        Log.llm.sensitive("→ user[0..200]: \(user.prefix(200))")

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
            provider: providerPreference,
            response_format: jsonMode ? ResponseFormat(type: "json_object") : nil,
            temperature: temperature,
            stream: nil
        )
        let body = try JSONEncoder().encode(ProxyEnvelope(kind: "chat", payload: payload))

        do {
            let data = try await postToProxyWithRetry(body: body)
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
                Log.llm.error("empty content")
                throw ClientError.emptyResponse
            }
            Log.llm.info("← OK len=\(text.count)")
            Log.llm.sensitive("← reply[0..200]: \(text.prefix(200))")
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
            Log.llm.error("JSON decode failed: \(error.localizedDescription)")
            Log.llm.sensitive("JSON decode failed body[0..200]=\(String(cleaned.prefix(200)))")
            throw ClientError.decodingFailed(error.localizedDescription)
        }
    }

    /// Streaming chat completion. Yields plain-text deltas as the model produces
    /// them so the UI can render a live answer instead of waiting for the whole
    /// completion (the "Suggest reply" latency win). The proxy streams the
    /// upstream SSE through verbatim; we parse OpenRouter's
    /// `{choices:[{delta:{content}}]}` chunks and yield `content`.
    ///
    /// No client-side retry: streamed bytes can't be replayed mid-flight, so the
    /// resilience here is the server-side `models = [primary, fallback]` chain.
    /// The caller falls back to the one-shot `complete()` path if the stream
    /// fails before producing any token.
    func streamComplete(system: String, user: String, jsonMode: Bool = false) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let payload = ChatRequest(
                        model: model,
                        models: [model, fallbackModel],
                        messages: [
                            .init(role: "system", content: system),
                            .init(role: "user", content: user)
                        ],
                        provider: providerPreference,
                        response_format: jsonMode ? ResponseFormat(type: "json_object") : nil,
                        temperature: nil,
                        stream: true
                    )
                    let body = try JSONEncoder().encode(ProxyEnvelope(kind: "chat", payload: payload))
                    let request = try await makeProxyRequest(body: body)

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw ClientError.decodingFailed("Non-HTTP response")
                    }
                    try throwIfGatedStatus(http)
                    if http.statusCode >= 400 {
                        // Error responses aren't SSE — reassemble the body,
                        // preserving newlines so a multi-line JSON / HTML error
                        // isn't mangled before `sanitizeErrorBody` parses it.
                        var lines: [String] = []
                        for try await line in bytes.lines {
                            lines.append(line)
                        }
                        throw ClientError.requestFailed(status: http.statusCode, body: Self.sanitizeErrorBody(lines.joined(separator: "\n")))
                    }

                    var produced = 0
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        // Skip SSE comments (": OPENROUTER PROCESSING" keepalives) and blanks.
                        guard trimmed.hasPrefix("data:") else { continue }
                        let data = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        if data == "[DONE]" { break }
                        guard let chunkData = data.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(StreamChunk.self, from: chunkData),
                              let delta = chunk.choices.first?.delta.content,
                              !delta.isEmpty else { continue }
                        produced += delta.count
                        continuation.yield(delta)
                    }
                    Log.llm.info("← stream done chars=\(produced)")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Pulls the JSON value out of a model response that may be fenced and/or
    /// padded with prose. Handles the shapes seen in the wild: a bare object, a
    /// fenced object, and — the one that used to break decoding — a fenced
    /// object followed by an explanatory paragraph (e.g. Gemini appending "The
    /// transcript is too vague…" *after* the closing ```). Drops the fence
    /// (everything from the closing ``` onward), then narrows to the outermost
    /// `{…}` / `[…]` so leading or trailing prose can't reach the decoder.
    static func extractJSON(_ s: String) -> String {
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
    static func isTransient(_ error: ClientError) -> Bool {
        switch error {
        case let .requestFailed(status, _):
            status == 429 || (status >= 500 && status < 600)
        case .networkFailed:
            true
        case .unauthenticated, .updateRequired, .deviceConflict, .entitlementRequired, .emptyResponse, .decodingFailed:
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
    static func retryDelayMillis(for error: ClientError, attempt: Int) -> UInt64 {
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
    /// `prompt` is the rolling context tail (last confirmed words for this
    /// source) — Whisper conditions decoding on it, which restores the context
    /// that per-chunk isolation otherwise destroys (proper nouns, spelling,
    /// phrase endings) and biases language toward what's already been said.
    /// `temperature: 0` + `verbose_json` are always requested: zero temperature
    /// cuts decode variance/hallucination, and the verbose response carries the
    /// per-segment metrics the caller filters on. The decoder tolerates a plain
    /// `{ text }` response too, so a provider that ignores `verbose_json` still
    /// works (just with empty `segments`).
    func transcribe(audio: Data, language: String? = nil, prompt: String? = nil) async throws -> Transcription {
        let promptText = (prompt?.isEmpty == false) ? prompt : nil
        let inner = TranscriptionRequest(
            model: whisperModel,
            input_audio: .init(data: audio.base64EncodedString(), format: "wav"),
            language: language,
            prompt: promptText,
            temperature: 0,
            response_format: "verbose_json"
        )
        let bodyData = try JSONEncoder().encode(ProxyEnvelope(kind: "transcribe", payload: inner))

        Log.llm.info(
            "→ transcribe via proxy model=\(whisperModel) audio_bytes=\(audio.count) body_bytes=\(bodyData.count) lang=\(language ?? "auto") prompt=\(promptText != nil)"
        )

        let data = try await postToProxyWithRetry(body: bodyData)
        do {
            let decoded = try JSONDecoder().decode(WhisperResponse.self, from: data)
            let text = decoded.text ?? ""
            let segments = (decoded.segments ?? []).map {
                TranscriptionSegment(
                    text: $0.text ?? "",
                    avgLogprob: $0.avg_logprob,
                    noSpeechProb: $0.no_speech_prob,
                    compressionRatio: $0.compression_ratio
                )
            }
            Log.llm.info("← Whisper OK len=\(text.count) segs=\(segments.count) lang=\(decoded.language ?? "?")")
            return Transcription(text: text, segments: segments, language: decoded.language)
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

    // MARK: - Single-device lock

    /// Claims this device's slot for the signed-in account. Throws
    /// `.deviceConflict` (after broadcasting `.nodDeviceConflict`) when the
    /// account is already bound to another device. Called right after sign-in
    /// so a blocked device is told immediately, before onboarding.
    func claimDevice() async throws {
        _ = try await postToProxyWithRetry(body: deviceEnvelope(kind: "device_claim"))
    }

    /// Releases this device's slot so the account can sign in elsewhere without
    /// waiting for the inactivity TTL. Best-effort — called during sign-out, so
    /// a failure (already offline, expiring token) must not block it.
    func releaseDevice() async {
        do {
            _ = try await postToProxy(body: deviceEnvelope(kind: "device_release"))
        } catch {
            Log.llm.error("releaseDevice failed (non-fatal): \(error.localizedDescription)")
        }
    }

    private func deviceEnvelope(kind: String) throws -> Data {
        try JSONEncoder().encode(ProxyEnvelope(kind: kind, payload: EmptyPayload()))
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

    /// Builds an authenticated proxy `URLRequest`, transparently refreshing the
    /// JWT when the cached token is expired. Shared by the buffered
    /// (`postToProxy`) and streaming (`streamComplete`) transports.
    ///
    /// The async session accessor matters: the previous sync read of
    /// `currentSession?.accessToken` would happily send a stale token while the
    /// SDK's background refresh was in flight → proxy 401 → user sees "Session
    /// expired" mid-meeting even though a valid refreshed token landed
    /// milliseconds later. A long recording crossing the 1h JWT TTL would make
    /// the summary or a chunk transcription fall off a cliff.
    private func makeProxyRequest(body: Data) async throws -> URLRequest {
        guard let supabase else {
            Log.llm.error("no Supabase client — request blocked")
            throw ClientError.unauthenticated
        }

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
        // Single-device lock: the proxy binds the account to this hardware id
        // and 409s any other device. Name is percent-encoded — machine names
        // aren't ASCII-safe, which an HTTP header value must be.
        request.setValue(DeviceIdentity.id, forHTTPHeaderField: "x-device-id")
        if let encodedName = DeviceIdentity.encodedName {
            request.setValue(encodedName, forHTTPHeaderField: "x-device-name")
        }
        request.httpBody = body
        return request
    }

    /// Maps the proxy's gated HTTP statuses (auth / update-required /
    /// device-conflict) to the matching `ClientError`, broadcasting the
    /// side-effect notifications the app observes. Shared by the buffered
    /// (`postToProxy`) and streaming (`streamComplete`) transports so a new
    /// gated status is added in one place. Does NOT handle the generic
    /// `>= 400` body — callers surface that from their own (buffered `Data`
    /// vs reassembled SSE) body source.
    private func throwIfGatedStatus(_ http: HTTPURLResponse) throws {
        switch http.statusCode {
        case 401:
            throw ClientError.unauthenticated
        case 426:
            // Proxy rejected a build below `minimum_build`. Flip the gate so the
            // update screen shows even if the launch check was skipped.
            NotificationCenter.default.post(name: .nodUpdateRequired, object: nil)
            throw ClientError.updateRequired
        case 409:
            // Single-device lock: the account is bound to another device.
            // Broadcast so the app signs out and explains why instead of
            // surfacing a raw HTTP error.
            NotificationCenter.default.post(name: .nodDeviceConflict, object: nil)
            throw ClientError.deviceConflict
        default:
            break
        }
    }

    /// True when a 403 body is the proxy's plan/feature gate
    /// (`{ "error": "entitlement_required" | "feature_required" }`) rather than
    /// the unrelated ownership 403 (`"meeting does not belong to user"`), which
    /// must stay a hard error.
    private static func isEntitlementError(_ data: Data) -> Bool {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = parsed["error"] as? String else { return false }
        return error == "entitlement_required" || error == "feature_required"
    }

    private func postToProxy(body: Data) async throws -> Data {
        let request = try await makeProxyRequest(body: body)

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
        // Operational visibility: the proxy stamps the serving STT provider on
        // transcribe responses. Logging it here (one line per chunk) makes it
        // obvious in Console.app / Xcode whether Groq is actually handling audio.
        if let sttProvider = http.value(forHTTPHeaderField: "x-nod-stt-provider") {
            Log.llm.info("STT served by provider=\(sttProvider) status=\(http.statusCode)")
        }
        try throwIfGatedStatus(http)
        if http.statusCode == 403, Self.isEntitlementError(data) {
            // Backstop for an entitlement that lapsed mid-session (trial
            // expired, subscription canceled) after the client-side start gate
            // passed — chunks then 403 one after another. Route the user to the
            // paywall instead of silently dropping transcription. The ownership
            // 403 ("meeting does not belong to user") is a genuine error and
            // falls through to `requestFailed` below.
            Log.llm.error("proxy 403 entitlement — opening paywall")
            NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
            throw ClientError.entitlementRequired
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
    static func sanitizeErrorBody(_ body: String) -> String {
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

/// Body for proxy calls that carry no payload (device claim/release); the proxy
/// still requires `payload` to be present, so we send an empty object.
private struct EmptyPayload: Encodable {}

extension Notification.Name {
    /// Posted by `LLMProxyClient` when the proxy refuses a call because the
    /// account is bound to another device (HTTP 409 `device_conflict`).
    /// `AppDelegate` observes it to force a sign-out with an explanation.
    static let nodDeviceConflict = Notification.Name("nod.auth.deviceConflict")
}

private struct TranscriptionRequest: Encodable {
    struct InputAudio: Encodable {
        let data: String
        let format: String
    }

    let model: String
    let input_audio: InputAudio
    let language: String?
    // Tier-1 knobs. All optional: a `nil` is omitted by the synthesized encoder
    // (`encodeIfPresent`), so the current call site — which sets none of them —
    // produces the exact same wire body as before. The proxy forwards whichever
    // are present to the provider's multipart form.
    let prompt: String?
    let temperature: Double?
    let response_format: String?
    let timestamp_granularities: [String]?

    init(
        model: String,
        input_audio: InputAudio,
        language: String? = nil,
        prompt: String? = nil,
        temperature: Double? = nil,
        response_format: String? = nil,
        timestamp_granularities: [String]? = nil
    ) {
        self.model = model
        self.input_audio = input_audio
        self.language = language
        self.prompt = prompt
        self.temperature = temperature
        self.response_format = response_format
        self.timestamp_granularities = timestamp_granularities
    }
}

/// Decodes either the plain (`{ text }`) or `verbose_json` transcription
/// response. `segments` carries the per-segment quality metrics the Tier-1
/// hallucination filter keys off (`avg_logprob`, `no_speech_prob`,
/// `compression_ratio`); `words` carries word-level timestamps for click-to-seek.
/// Both are nil on the plain response, so existing callers that read only `text`
/// keep working unchanged.
private struct WhisperResponse: Decodable {
    struct Segment: Decodable {
        let text: String?
        let start: Double?
        let end: Double?
        let avg_logprob: Double?
        let no_speech_prob: Double?
        let compression_ratio: Double?
    }

    struct Word: Decodable {
        let word: String?
        let start: Double?
        let end: Double?
    }

    let text: String?
    let language: String?
    let segments: [Segment]?
    let words: [Word]?
}

/// Provider-agnostic transcription result handed to the transcriber. `segments`
/// is non-empty only when the provider honored `verbose_json`; the transcriber's
/// hallucination filter uses the per-segment metrics when present and falls back
/// to text-only heuristics when absent.
struct Transcription {
    let text: String
    let segments: [TranscriptionSegment]
    let language: String?
}

struct TranscriptionSegment {
    let text: String
    let avgLogprob: Double?
    let noSpeechProb: Double?
    let compressionRatio: Double?
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
    let stream: Bool?
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

/// One SSE chunk of a streamed chat completion. `choices` is empty on the
/// terminal usage-only chunk and `delta.content` is nil on the role-priming
/// first chunk — both decode cleanly and yield nothing.
private struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta
    }

    let choices: [Choice]
}
