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
        case requestFailed(status: Int, body: String)
        case emptyResponse
        case decodingFailed(String)
        case networkFailed(Error)

        var errorDescription: String? {
            switch self {
            case .unauthenticated:
                return "Session expired, please sign in again."
            case .requestFailed(let status, let body):
                return "LLM proxy HTTP \(status): \(body)"
            case .emptyResponse:
                return "LLM proxy returned an empty response."
            case .decodingFailed(let detail):
                return "Failed to decode proxy response: \(detail)"
            case .networkFailed(let error):
                return "Network error: \(error.localizedDescription)"
            }
        }
    }

    /// Chat model override — kept in UserDefaults so devs can A/B models
    /// without rebuilding. Default points at Gemini 2.0 Flash via OpenRouter.
    var model: String {
        UserDefaults.standard.string(forKey: "openrouter.model") ?? "google/gemini-2.0-flash-001"
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
        config.timeoutIntervalForRequest = 70   // proxy enforces 60s for transcribe; give it slack
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    init(supabase: SupabaseClient? = nil) {
        self.supabase = supabase
        self.proxyURL = SupabaseConfig.url.appendingPathComponent("functions/v1/llm-proxy")
    }

    // MARK: - Chat completion

    func complete(system: String, user: String, jsonMode: Bool = false) async throws -> String {
        let userPreview = String(user.prefix(200))
        Log.llm.info("→ chat via proxy model=\(model) system.len=\(system.count) user.len=\(user.count) jsonMode=\(jsonMode)")
        Log.llm.info("→ user preview: \(userPreview)\(user.count > 200 ? "…" : "")")

        let payload = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user)
            ],
            response_format: jsonMode ? ResponseFormat(type: "json_object") : nil
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
    /// still wrap valid JSON in stray fences/preamble; we strip a leading
    /// ```json fence if present so a well-shaped payload survives a sloppy
    /// model. A genuinely malformed response surfaces as `.decodingFailed`.
    func completeJSON<T: Decodable>(system: String, user: String, as type: T.Type) async throws -> T {
        let raw = try await complete(system: system, user: user, jsonMode: true)
        let cleaned = Self.stripCodeFence(raw)
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

    private static func stripCodeFence(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var body = trimmed.dropFirst(3)
        // Tolerate any case of the "json" language hint (some models emit
        // ```JSON). Drop it whether or not a newline follows.
        if body.lowercased().hasPrefix("json") { body = body.dropFirst(4) }
        if let first = body.first, first == "\n" || first == "\r" {
            body = body.dropFirst()
        }
        if body.hasSuffix("```") {
            body = body.dropLast(3)
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True for errors that are plausibly fixed by a retry: upstream 5xx
    /// (provider hiccups), 429 (rate limits — time-bucketed, usually clear
    /// within seconds), and URLError-class transport blips. Excludes 4xx
    /// (other than 429), decoding errors, empty responses, and auth failures.
    private static func isTransient(_ error: ClientError) -> Bool {
        switch error {
        case .requestFailed(let status, _):
            return status == 429 || (status >= 500 && status < 600)
        case .networkFailed:
            return true
        case .unauthenticated, .emptyResponse, .decodingFailed:
            return false
        }
    }

    /// Exponential backoff in milliseconds. 429 gets a longer base because
    /// rate limits are time-bucketed — burning a 200ms retry the moment a
    /// 429 lands almost always re-trips the same bucket. 5xx / network blips
    /// retry sooner since they're usually fixed by the next request.
    private static func retryDelayMillis(for error: ClientError, attempt: Int) -> UInt64 {
        let base: UInt64
        switch error {
        case .requestFailed(let status, _) where status == 429:
            base = 800
        default:
            base = 400
        }
        return base * UInt64(1 << attempt)  // 0→base, 1→2×base, 2→4×base
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

    // MARK: - Transport

    /// Wraps `postToProxy` with exponential-backoff retries on transient
    /// errors (5xx, 429, URLError). 429s in particular were dropping ~30% of
    /// Whisper chunks on the OpenRouter free tier, which is what made the
    /// "Suggest reply" answers go stale mid-meeting.
    private func postToProxyWithRetry(body: Data) async throws -> Data {
        let maxAttempts = 3
        var lastError: ClientError = .emptyResponse
        for attempt in 0..<maxAttempts {
            do {
                return try await postToProxy(body: body)
            } catch let error as ClientError {
                lastError = error
                let isLastAttempt = attempt == maxAttempts - 1
                if !isLastAttempt && Self.isTransient(error) {
                    let delayMs = Self.retryDelayMillis(for: error, attempt: attempt)
                    Log.llm.error("transient error on attempt \(attempt + 1)/\(maxAttempts) — retrying in \(delayMs)ms: \(error.localizedDescription)")
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
                let slice = trimmed[titleOpen.upperBound..<titleClose.lowerBound]
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
           let err = parsed["error"] as? Any {
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
    let messages: [Message]
    let response_format: ResponseFormat?
}

private struct ResponseFormat: Encodable {
    let type: String
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}
