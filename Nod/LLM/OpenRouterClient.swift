import Foundation

@MainActor
final class OpenRouterClient: ObservableObject {
    enum ClientError: LocalizedError {
        case missingAPIKey
        case requestFailed(status: Int, body: String)
        case emptyResponse
        case decodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "OpenRouter API key not set. Run `defaults write com.example.nod openrouter.apiKey <your-key>` and relaunch."
            case .requestFailed(let status, let body):
                return "OpenRouter HTTP \(status): \(body)"
            case .emptyResponse:
                return "OpenRouter returned an empty response."
            case .decodingFailed(let detail):
                return "Failed to decode OpenRouter response: \(detail)"
            }
        }
    }

    var apiKey: String? {
        if let stored = UserDefaults.standard.string(forKey: "openrouter.apiKey"), !stored.isEmpty {
            return stored
        }
        return ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
    }

    var model: String {
        UserDefaults.standard.string(forKey: "openrouter.model") ?? "google/gemini-2.0-flash-001"
    }

    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    // Whisper / audio transcription config — overridable via UserDefaults but
    // defaults to OpenRouter (same provider, same API key, same chat endpoint).
    private var whisperBaseURL: String {
        UserDefaults.standard.string(forKey: "whisper.baseURL") ?? "https://openrouter.ai/api/v1"
    }
    private var whisperModel: String {
        UserDefaults.standard.string(forKey: "whisper.model") ?? "openai/whisper-1"
    }
    private var whisperAPIKey: String? {
        if let dedicated = UserDefaults.standard.string(forKey: "whisper.apiKey"), !dedicated.isEmpty {
            return dedicated
        }
        return apiKey
    }

    func complete(system: String, user: String) async throws -> String {
        guard let key = apiKey, !key.isEmpty else {
            Log.llm.error("missing API key")
            throw ClientError.missingAPIKey
        }

        let userPreview = String(user.prefix(200))
        Log.llm.info("→ POST model=\(model) system.len=\(system.count) user.len=\(user.count)")
        Log.llm.info("→ user preview: \(userPreview)\(user.count > 200 ? "…" : "")")

        let payload = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user)
            ]
        )
        let body = try JSONEncoder().encode(payload)

        // One automatic retry on transient 5xx (upstream provider hiccups,
        // e.g. Google returning 504 "operation aborted" from Gemini Flash).
        var lastError: ClientError?
        for attempt in 0..<2 {
            do {
                return try await postChat(key: key, body: body)
            } catch let error as ClientError {
                if case let .requestFailed(status, _) = error, status >= 500, status < 600, attempt == 0 {
                    Log.llm.error("transient \(status) on attempt \(attempt + 1) — retrying once after 700ms")
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    lastError = error
                    continue
                }
                throw error
            }
        }
        throw lastError ?? ClientError.emptyResponse
    }

    /// Single HTTP attempt for the chat completion call.
    private func postChat(key: String, body: Data) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("https://github.com/nod-app", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Nod", forHTTPHeaderField: "X-Title")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.decodingFailed("Non-HTTP response")
        }
        if http.statusCode >= 400 {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            let sanitized = Self.sanitizeErrorBody(raw)
            Log.llm.error("HTTP \(http.statusCode): \(sanitized) (raw=\(raw.count)b)")
            throw ClientError.requestFailed(status: http.statusCode, body: sanitized)
        }
        do {
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
            Log.llm.error("decoding failed: \(error.localizedDescription)")
            throw ClientError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Whisper (audio transcription)

    /// POSTs an audio blob to OpenRouter's /api/v1/audio/transcriptions.
    ///
    /// OpenRouter's transcription endpoint is JSON-bodied (NOT multipart like
    /// OpenAI's direct API): the audio goes under `input_audio` as a
    /// base64-encoded `data` string with a `format` tag. Sending multipart
    /// gets a generic 500 from their handler.
    func transcribe(audio: Data, fileName: String = "audio.wav", language: String = "en") async throws -> String {
        guard let key = whisperAPIKey, !key.isEmpty else {
            Log.llm.error("Whisper: missing API key (set `whisper.apiKey` or `openrouter.apiKey`)")
            throw ClientError.missingAPIKey
        }
        let base = whisperBaseURL.hasSuffix("/")
            ? String(whisperBaseURL.dropLast())
            : whisperBaseURL
        guard let url = URL(string: "\(base)/audio/transcriptions") else {
            throw ClientError.decodingFailed("invalid whisper.baseURL: \(whisperBaseURL)")
        }

        let payload = TranscriptionRequest(
            model: whisperModel,
            input_audio: .init(data: audio.base64EncodedString(), format: "wav"),
            language: language
        )
        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(payload)
        } catch {
            throw ClientError.decodingFailed("failed to encode transcription body: \(error)")
        }

        Log.llm.info("→ Whisper POST \(url.absoluteString) model=\(whisperModel) audio_bytes=\(audio.count) body_bytes=\(bodyData.count) lang=\(language)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/nod-app", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Nod", forHTTPHeaderField: "X-Title")
        request.httpBody = bodyData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.decodingFailed("Non-HTTP response")
        }
        if http.statusCode >= 400 {
            let rawBody = String(data: data, encoding: .utf8) ?? "<binary>"
            let sanitized = Self.sanitizeErrorBody(rawBody)
            Log.llm.error("Whisper HTTP \(http.statusCode): \(sanitized) (raw=\(rawBody.count)b)")
            throw ClientError.requestFailed(status: http.statusCode, body: sanitized)
        }
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

    /// Reduce arbitrary error response bodies (HTML pages, giant JSON with
    /// nested metadata, etc.) to something short and human-readable so they
    /// don't flood log/UI.
    private static func sanitizeErrorBody(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        // HTML error page → grab <title>.
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

        // OpenRouter / OpenAI JSON error shape: {"error": {"message": "...", "code": N, "metadata": {...}}}
        // Extract just the message + provider name if present.
        if let data = trimmed.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = parsed["error"] as? [String: Any] {
            let message = (err["message"] as? String) ?? ""
            var providerHint = ""
            if let metadata = err["metadata"] as? [String: Any],
               let provider = metadata["provider_name"] as? String {
                providerHint = " (via \(provider))"
            }
            if !message.isEmpty {
                return String(message.prefix(220)) + providerHint
            }
        }

        return String(trimmed.prefix(240))
    }

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
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}
