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
        case meetingLimitReached
        /// A recording cannot start for a reason the user can resolve in the app
        /// (another meeting is still finishing). Deliberately NOT a 409: that
        /// status means the single-device lock and signs the user out.
        case meetingBlocked(String)
        case requestFailed(status: Int, body: String)
        case emptyResponse
        case decodingFailed(String)
        case networkFailed(Error)
        case indexIncomplete(indexed: Int, total: Int)

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
            case .meetingLimitReached:
                "You've used this period's capture hours."
            case let .meetingBlocked(reason):
                reason
            case let .requestFailed(status, body):
                "LLM proxy HTTP \(status): \(body)"
            case .emptyResponse:
                "LLM proxy returned an empty response."
            case let .decodingFailed(detail):
                "Failed to decode proxy response: \(detail)"
            case let .networkFailed(error):
                "Network error: \(error.localizedDescription)"
            case let .indexIncomplete(indexed, total):
                "Indexed only \(indexed) of \(total) transcript chunks."
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

    /// Model for the user-facing Q&A chat (`chat(system:history:)`) only — NOT
    /// the summary/recap/title generation, which stays on `model` above.
    ///
    /// This is the one call whose output the user reads word for word, so it
    /// gets the strongest model of the three. It ran on Haiku 4.5 to save cost,
    /// but the saving was misplaced: the answer is the quality-sensitive step,
    /// while the two JSON prep calls that surround it — which were on Sonnet —
    /// are not. They now run on `utilityModel`, which pays for most of this.
    /// Override for an A/B with
    /// `defaults write com.example.nod openrouter.model.chat "anthropic/claude-haiku-4.5"`.
    private static let chatModelKey = "openrouter.model.chat"
    var chatModel: String {
        UserDefaults.standard.string(forKey: Self.chatModelKey) ?? "anthropic/claude-sonnet-5"
    }

    /// Model for the meeting title (`RecapGenerator.title(from:language:)`)
    /// only — split out from `model` so a summary/recap model change can roll
    /// out without silently moving title too. Same default as `model` today,
    /// so splitting this out is a zero-behavior-change step on its own;
    /// override with `defaults write com.example.nod openrouter.model.title "..."`.
    private static let titleModelKey = "openrouter.model.title"
    var titleModel: String {
        UserDefaults.standard.string(forKey: Self.titleModelKey) ?? "anthropic/claude-sonnet-4.6"
    }

    /// Model for the structured prep calls that never reach the user: rewriting
    /// a follow-up into a standalone query (+ its HyDE passage) and routing a
    /// question to a scope. Both emit a fixed JSON schema from a prompt of a
    /// couple of thousand characters — there is nothing for a reasoning-class
    /// model to do, and running two of them on Sonnet added ~4.5s of latency
    /// before retrieval even started.
    /// Override with `defaults write com.example.nod openrouter.model.utility "..."`.
    private static let utilityModelKey = "openrouter.model.utility"
    var utilityModel: String {
        UserDefaults.standard.string(forKey: Self.utilityModelKey) ?? "anthropic/claude-haiku-4.5"
    }

    /// Provider routing hints for the chat call. The `google-vertex` pin +
    /// `google-ai-studio` ignore exist solely to dodge Google's shared free-tier
    /// 429s (see the routing note in `send`); they only apply to Google models.
    /// For a non-Google primary (e.g. Claude) those hints would needlessly
    /// constrain routing — Claude is also served via Vertex on OpenRouter, so
    /// pinning the order there would silence Anthropic's own infra — so we send
    /// no order/ignore and let OpenRouter pick the best provider.
    /// Whether a model still accepts `temperature`.
    ///
    /// Anthropic removed the sampling parameters from Sonnet 5, Opus 4.7 and
    /// later, and the Fable/Mythos line: a non-default `temperature` is
    /// rejected outright, and OpenRouter lists none of them in that model's
    /// `supported_parameters`. Sending 0.2 anyway costs the call — either it
    /// 400s and silently falls through to the next model in the chain, or the
    /// grounding we set it for is quietly dropped. Older models keep it.
    static func acceptsTemperature(_ model: String) -> Bool {
        let withoutSampling = [
            "claude-sonnet-5",
            "claude-sonnet-latest",
            "claude-opus-4.7",
            "claude-opus-4.8",
            "claude-opus-latest",
            "claude-fable",
            "claude-mythos"
        ]
        return !withoutSampling.contains { model.contains($0) }
    }

    /// Which routing category a call belongs to, for the proxy's `task` field —
    /// which is what `model-policy.ts` routes on. Matched against the three
    /// explicit model properties rather than passed by each call site — every
    /// call already resolves to exactly one of them, so this reuses that instead
    /// of threading a parallel `task:` argument through `complete`/`chat`/
    /// `completeJSON`/`streamChat` and every one of their callers.
    ///
    /// Takes the caller's OPTIONAL `primaryModel`, not the resolved one, and
    /// that is the whole point: `titleModel` and `model` share a default id, so
    /// matching on the resolved value labelled every summary, recap, entity and
    /// speaker-naming call `title` — the first case that happened to match —
    /// and routed all of them by `TITLE_MODEL`, leaving `SUMMARY_MODEL` dead.
    /// Only the title call passes `titleModel` explicitly; a nil primary is a
    /// summary-class call by construction and can never be mistaken for one.
    private func taskLabel(for primaryModel: String?) -> String {
        guard let primaryModel else { return "summary" }
        return switch primaryModel {
        case chatModel: "chat"
        case utilityModel: "utility"
        case titleModel: "title"
        default: "summary"
        }
    }

    /// Whether to spend output tokens on a chain of thought. Derived from the
    /// routing category rather than passed per call, for the same reason
    /// `taskLabel` is: every utility call is `completeJSON` against a fixed
    /// schema — the live pass, the HyDE search rewrite, the session router —
    /// and none of them has anything to work out.
    ///
    /// Measured on a 46-minute meeting: the live analyst's replies were 13–614
    /// characters but billed 82–504 completion tokens, so roughly 88% of what
    /// we paid for on that call was reasoning nothing read. Output bills at
    /// ~4× input. nil leaves the model's own default alone.
    private func reasoning(for primaryModel: String) -> Reasoning? {
        taskLabel(for: primaryModel) == "utility" ? Reasoning(enabled: false) : nil
    }

    private func providerPreference(for primaryModel: String) -> ProviderPreference {
        guard primaryModel.hasPrefix("google/") else {
            return ProviderPreference(order: nil, ignore: nil, allow_fallbacks: true)
        }
        return ProviderPreference(order: ["google-vertex"], ignore: ["google-ai-studio"], allow_fallbacks: true)
    }

    /// Speech-to-text model override.
    ///
    /// Default is `gpt-4o-transcribe` rather than any Whisper build because
    /// Whisper conditions its decoder on **one** language token per segment: it
    /// picks a language for the chunk and renders the whole chunk in it,
    /// translating the rest. A Ukrainian sentence carrying English loanwords
    /// ("зроби апрув на реліз") therefore comes back wholly English or wholly
    /// Ukrainian — never as it was spoken. No prompt, temperature or language
    /// pin fixes that; it is what the architecture does. `gpt-4o-transcribe` has
    /// no such single-language token and keeps code-switching intact, which is
    /// the property this product is built on.
    ///
    /// Whisper stays one `defaults write com.example.nod whisper.model
    /// "openai/whisper-large-v3"` away — for an A/B, or if the new model's cost
    /// or latency turns out worse in practice.
    private var whisperModel: String {
        UserDefaults.standard.string(forKey: Self.whisperModelKey) ?? "openai/gpt-4o-transcribe"
    }

    /// `verbose_json` — and with it the per-segment metrics the hallucination
    /// filter prefers and the detected language — is a Whisper-only format;
    /// `gpt-4o-transcribe` rejects it outright, and a 400 is deliberately not
    /// failed over. Both consumers already treat the extra fields as optional
    /// (`Transcription.segments`, `HallucinationFilter`).
    private var whisperResponseFormat: String {
        whisperModel.contains("whisper") ? "verbose_json" : "json"
    }

    private let proxyURL: URL
    private let supabase: SupabaseClient?
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 70 // proxy enforces 60s for transcribe; give it slack
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    /// Generating a recap is not an interactive request and must not be held to
    /// an interactive ceiling.
    ///
    /// A 1h19m meeting reached the model as a 31k-token prompt and took 185
    /// seconds to answer. The server finished and returned 200; the chat session
    /// had already given up, so the recap was paid for and thrown away, and the
    /// meeting was left with "a summary couldn't be generated". Long meetings
    /// are exactly the ones a recap is worth most for.
    ///
    /// `timeoutIntervalForRequest` still guards a stalled model — it measures the
    /// gap between packets, not the whole answer — so a stream that stops
    /// producing fails in three minutes rather than hanging on the resource
    /// ceiling.
    private let generationSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config)
    }()

    /// Dedicated session for audio transcription. `waitsForConnectivity` lets the
    /// OS park a chunk upload while the link is down and fire it the moment
    /// connectivity returns — so a Wi-Fi drop at the *start* of an upload no
    /// longer instantly fails and discards the segment (NOD-29). It only covers
    /// connection *establishment*; a drop mid-upload still throws
    /// `NSURLErrorNetworkConnectionLost`, which the app-level retry queue in
    /// `WhisperTranscriber` catches. `timeoutIntervalForResource` bounds the
    /// wait, so a genuinely long outage still fails (into that queue) rather than
    /// hanging forever. Kept separate from the chat session, which stays
    /// fast-fail: interactive chat wants an immediate error + its own fallback,
    /// not a silent 2-minute wait.
    private let transcribeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 70
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = true
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
        enum Role: String { case user, assistant, tool }
        let role: Role
        let content: String
        /// Set on the assistant turn that asked for tools. The provider rejects
        /// a `tool` result whose originating call isn't in the history, so the
        /// request has to replay the call verbatim.
        var toolCalls: [ChatToolCall] = []
        /// Set on a `tool` turn: which call this answers.
        var toolCallID: String?
    }

    /// One thing a streamed turn produced. Tool calls can't be streamed to the
    /// user — they arrive in fragments and mean nothing until whole — so they
    /// surface once, at the end, as a single event.
    enum ChatStreamEvent: Equatable {
        case delta(String)
        case toolCalls([ChatToolCall])
    }

    func complete(
        system: String,
        user: String,
        jsonMode: Bool = false,
        primaryModel: String? = nil,
        longRunning: Bool = false
    ) async throws -> String {
        Log.llm.info(
            "→ chat via proxy model=\(primaryModel ?? model) fallback=\(fallbackModel) system.len=\(system.count) user.len=\(user.count) jsonMode=\(jsonMode)"
        )
        Log.llm.sensitive("→ user[0..200]: \(user.prefix(200))")

        return try await send(
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user)
            ],
            jsonMode: jsonMode,
            primaryModel: primaryModel,
            longRunning: longRunning
        )
    }

    /// Multi-turn chat: a system prompt followed by the running
    /// user/assistant history. Used by single-session chat (step 3). The
    /// transcript + recap live in `system`; `history` is just the dialogue.
    ///
    /// `cachePrompt` must be false when the caller's `system` ends in content
    /// that changes per question. The breakpoint sits at the end of the system
    /// message, so a varying tail means the prefix is never the same twice: the
    /// cache is written on every call and read on none, and a write costs 1.25×
    /// what the tokens would have cost uncached. Only a caller whose `system` is
    /// stable across turns — a meeting's transcript and recap — profits from it.
    func chat(
        system: String,
        history: [ChatTurn],
        temperature: Double? = nil,
        cachePrompt: Bool = true
    ) async throws -> String {
        Log.llm.info("→ multi-turn chat via proxy model=\(chatModel) system.len=\(system.count) turns=\(history.count)")
        return try await send(
            messages: Self.messages(system: system, history: history),
            jsonMode: false,
            temperature: temperature,
            primaryModel: chatModel,
            cachePrompt: cachePrompt
        )
    }

    /// The primary model followed by the other configured ones, deduped and
    /// order-preserving. OpenRouter walks this list when a model fails for any
    /// reason, so a chat that leads with the cheap model still escalates.
    private func fallbackChain(from primary: String) -> [String] {
        var chain: [String] = []
        for candidate in [primary, model, fallbackModel] where !chain.contains(candidate) {
            chain.append(candidate)
        }
        return chain
    }

    /// Shared transport for every chat call. Applies the same provider
    /// routing + model fallback chain used across the app (see the strategy
    /// note below) and decodes the assistant message.
    private func send(
        messages: [ChatRequest.Message],
        jsonMode: Bool,
        temperature: Double? = nil,
        primaryModel: String? = nil,
        cachePrompt: Bool = false,
        longRunning: Bool = false
    ) async throws -> String {
        // `primaryModel` overrides the default for a specific call purpose (the
        // Q&A chat runs on the cheaper `chatModel`); summary/recap generation
        // passes nil and stays on `model`. The retry chain is the primary
        // followed by the other two configured models, deduped and order-
        // preserving — so a chat that leads with Haiku still escalates to Sonnet
        // on failure, while a summary call keeps its original [model, fallback].
        let primary = primaryModel ?? model
        let chain = fallbackChain(from: primary)
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
        // `models = chain` (primary, then the other configured models, deduped)
        // is the model-level retry chain. If
        // the primary fails for ANY reason (provider outage, 429 on every
        // route, content policy block), OpenRouter retries with the fallback
        // automatically — same response shape, transparent to the client.
        let payload = ChatRequest(
            model: primary,
            models: chain,
            messages: messages,
            provider: providerPreference(for: primary),
            response_format: jsonMode ? ResponseFormat(type: "json_object") : nil,
            temperature: Self.acceptsTemperature(primary) ? temperature : nil,
            stream: nil,
            cache_prompt: cachePrompt ? true : nil,
            reasoning: reasoning(for: primary),
            task: taskLabel(for: primaryModel)
        )
        let body = try JSONEncoder().encode(ProxyEnvelope(kind: "chat", payload: payload))

        do {
            let data = try await postToProxyWithRetry(
                body: body,
                using: longRunning ? generationSession : nil
            )
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
    func completeJSON<T: Decodable>(
        system: String,
        user: String,
        as type: T.Type,
        primaryModel: String? = nil,
        longRunning: Bool = false
    ) async throws -> T {
        let raw = try await complete(
            system: system,
            user: user,
            jsonMode: true,
            primaryModel: primaryModel,
            longRunning: longRunning
        )
        let cleaned = Self.extractJSON(raw)
        guard let data = cleaned.data(using: .utf8) else {
            throw ClientError.decodingFailed("non-utf8 LLM response")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // Shape, not content: the body is the user's meeting, so it can only
            // be logged behind DEBUG — and `.debug` entries are evicted from the
            // log store within minutes, which is exactly when a failure report
            // arrives too late to reproduce. What survives here names the field
            // that did not fit, and field names are ours, not the user's.
            Log.llm.error("JSON decode failed: \(Self.shape(of: data)) — \(error.localizedDescription)")
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
    func streamComplete(
        system: String,
        user: String,
        jsonMode: Bool = false,
        longRunning: Bool = false
    ) -> AsyncThrowingStream<String, Error> {
        Self.textOnly(stream(
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user)
            ],
            jsonMode: jsonMode,
            longRunning: longRunning
        ))
    }

    /// The error behind a non-2xx streaming response. Error bodies aren't SSE,
    /// so the stream is drained as plain text — newlines preserved, or a
    /// multi-line JSON/HTML error is mangled before it can be parsed.
    private func streamFailure(status: Int, bytes: URLSession.AsyncBytes) async -> ClientError {
        var lines: [String] = []
        if let collected = try? await bytes.lines.reduce(into: [String]()) { $0.append($1) } {
            lines = collected
        }
        let raw = lines.joined(separator: "\n")
        if status == 403, Self.isEntitlementError(Data(raw.utf8)) {
            // Same plan/feature gate as postToProxy: route to the paywall with a
            // human message instead of surfacing a raw "HTTP 403" in the chat.
            Log.llm.error("stream 403 entitlement — opening paywall")
            NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
            return .entitlementRequired
        }
        return .requestFailed(status: status, body: Self.sanitizeErrorBody(raw))
    }

    /// One line of the upstream SSE body. Splitting this out keeps the read loop
    /// readable — the wire format has three outcomes and only one of them is a
    /// payload.
    private enum ServerSentLine {
        case ignored
        case done
        case delta(StreamChunk.Choice.Delta)
    }

    private static func parseServerSentLine(_ line: String) -> ServerSentLine {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Skip SSE comments (": OPENROUTER PROCESSING" keepalives) and blanks.
        guard trimmed.hasPrefix("data:") else { return .ignored }
        let data = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if data == "[DONE]" { return .done }
        guard let chunkData = data.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(StreamChunk.self, from: chunkData),
              let delta = chunk.choices.first?.delta
        else { return .ignored }
        return .delta(delta)
    }

    /// Drops tool-call events so a caller that only wants prose keeps the plain
    /// `String` stream it has always had.
    private static func textOnly(
        _ events: AsyncThrowingStream<ChatStreamEvent, Error>
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        if case let .delta(text) = event { continuation.yield(text) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The wire messages for a system prompt and a history.
    ///
    /// One mapping for the streamed and the one-shot path alike. They had two,
    /// and the one-shot copy dropped `tool_calls` and `tool_call_id` and sent
    /// `""` where the assistant turn needs no content at all — so replaying a
    /// finished tool round through it produced `tool` results answering nothing,
    /// which every provider rejects. It only ran when a question exhausted its
    /// tool rounds, which is why it survived.
    private static func messages(system: String, history: [ChatTurn]) -> [ChatRequest.Message] {
        var messages: [ChatRequest.Message] = [.init(role: "system", content: system)]
        messages += history.map { turn in
            ChatRequest.Message(
                role: turn.role.rawValue,
                content: turn.content.isEmpty ? nil : turn.content,
                tool_calls: turn.toolCalls.isEmpty ? nil : turn.toolCalls,
                tool_call_id: turn.toolCallID
            )
        }
        return messages
    }

    /// Streaming turn that may end in tool calls instead of prose. Content
    /// arrives as it always did; if the model asked for tools, a single
    /// `.toolCalls` event lands last and no text was produced.
    func streamChat(
        system: String,
        history: [ChatTurn],
        tools: [ChatTool],
        temperature: Double? = nil,
        cachePrompt: Bool = true
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        Log.llm.info("→ streaming chat model=\(chatModel) turns=\(history.count) tools=\(tools.count)")
        return stream(
            messages: Self.messages(system: system, history: history),
            tools: tools.map(ChatToolPayload.init),
            jsonMode: false,
            temperature: temperature,
            primaryModel: chatModel,
            cachePrompt: cachePrompt
        )
    }

    private func stream(
        messages: [ChatRequest.Message],
        tools: [ChatToolPayload] = [],
        jsonMode: Bool = false,
        temperature: Double? = nil,
        primaryModel: String? = nil,
        cachePrompt: Bool = false,
        longRunning: Bool = false
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Same primary-then-others chain as `send`, so a streamed
                    // call escalates on provider failure exactly like a
                    // one-shot one.
                    let primary = primaryModel ?? model
                    let chain = fallbackChain(from: primary)
                    var payload = ChatRequest(
                        model: primary,
                        models: chain,
                        messages: messages,
                        provider: providerPreference(for: primary),
                        response_format: jsonMode ? ResponseFormat(type: "json_object") : nil,
                        temperature: Self.acceptsTemperature(primary) ? temperature : nil,
                        stream: true,
                        cache_prompt: cachePrompt ? true : nil,
                        reasoning: reasoning(for: primary),
                        task: taskLabel(for: primaryModel)
                    )
                    payload.tools = tools.isEmpty ? nil : tools
                    let body = try JSONEncoder().encode(ProxyEnvelope(kind: "chat", payload: payload))
                    let request = try await makeProxyRequest(body: body)

                    let transport = longRunning ? generationSession : session
                    let (bytes, response) = try await transport.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw ClientError.decodingFailed("Non-HTTP response")
                    }
                    logRoutedModel(http)
                    try throwIfGatedStatus(http)
                    if http.statusCode >= 400 {
                        throw await streamFailure(status: http.statusCode, bytes: bytes)
                    }

                    var produced = 0
                    var toolCalls = ToolCallAccumulator()
                    readLoop: for try await line in bytes.lines {
                        try Task.checkCancellation()
                        switch Self.parseServerSentLine(line) {
                        case .ignored:
                            continue
                        case .done:
                            break readLoop
                        case let .delta(delta):
                            if let fragments = delta.tool_calls, !fragments.isEmpty {
                                toolCalls.absorb(fragments)
                            }
                            guard let text = delta.content, !text.isEmpty else { continue }
                            produced += text.count
                            continuation.yield(.delta(text))
                        }
                    }
                    let calls = toolCalls.calls()
                    if !calls.isEmpty {
                        Log.llm.info("← stream tool calls=\(calls.map(\.function.name).joined(separator: ","))")
                        continuation.yield(.toolCalls(calls))
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
    /// What a payload *is*, without saying what it contains — "object{speakers:
    /// array}" is enough to see that a model answered `{"speakers": []}` and
    /// nothing about the meeting it answered for. Keys are our own schema field
    /// names; values are described by type only, and never printed.
    static func shape(of data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return "not-json" }
        guard let object = json as? [String: Any] else { return kind(of: json) }
        let fields = object.keys.sorted().prefix(8).map { "\($0):\(kind(of: object[$0] as Any))" }
        return "object{\(fields.joined(separator: ","))}"
    }

    private static func kind(of value: Any) -> String {
        switch value {
        case is [String: Any]: "object"
        case let array as [Any]: "array[\(array.count)]"
        case is String: "string"
        case is NSNull: "null"
        case is NSNumber: "number"
        default: "?"
        }
    }

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
    nonisolated static func isTransient(_ error: ClientError) -> Bool {
        switch error {
        case let .requestFailed(status, _):
            status == 429 || (status >= 500 && status < 600)
        case .networkFailed:
            true
        case .unauthenticated, .updateRequired, .deviceConflict, .entitlementRequired, .meetingLimitReached,
             .meetingBlocked, .emptyResponse, .decodingFailed, .indexIncomplete:
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
    /// `meetingID` names the recording this chunk belongs to. The proxy checks it
    /// against the meeting's start lease and strips it before the payload reaches
    /// a provider — no chunk ever carries our identifiers upstream.
    func transcribe(
        audio: Data,
        meetingID: UUID,
        language: String? = nil,
        prompt: String? = nil
    ) async throws -> Transcription {
        let promptText = (prompt?.isEmpty == false) ? prompt : nil
        let inner = TranscriptionRequest(
            meeting_id: meetingID,
            model: whisperModel,
            input_audio: .init(data: audio.base64EncodedString(), format: "wav"),
            language: language,
            prompt: promptText,
            temperature: 0,
            response_format: whisperResponseFormat
        )
        let bodyData = try JSONEncoder().encode(ProxyEnvelope(kind: "transcribe", payload: inner))

        Log.llm.info(
            "→ transcribe via proxy model=\(whisperModel) audio_bytes=\(audio.count) body_bytes=\(bodyData.count) lang=\(language ?? "auto") prompt=\(promptText != nil)"
        )

        let data = try await postToProxyWithRetry(body: bodyData, using: transcribeSession)
        do {
            let decoded = try JSONDecoder().decode(WhisperResponse.self, from: data)
            let text = decoded.text ?? ""
            let segments = (decoded.segments ?? []).map {
                TranscriptionSegment(
                    text: $0.text ?? "",
                    avgLogprob: $0.avg_logprob,
                    noSpeechProb: $0.no_speech_prob,
                    compressionRatio: $0.compression_ratio,
                    start: $0.start,
                    end: $0.end
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

    /// A held-key question, spoken: one short clip with no meeting behind it,
    /// transcribed the same way a chunk is. The proxy's `dictate` kind takes no
    /// lease and caps the clip, so a question is never mistaken for a recording.
    func dictate(audio: Data) async throws -> Transcription {
        let inner = DictationRequest(
            model: whisperModel,
            input_audio: .init(data: audio.base64EncodedString(), format: "wav"),
            temperature: 0,
            response_format: whisperResponseFormat
        )
        Log.llm.info("→ dictate via proxy model=\(whisperModel) audio_bytes=\(audio.count)")
        let data = try await postToProxyWithRetry(
            body: JSONEncoder().encode(ProxyEnvelope(kind: "dictate", payload: inner)),
            using: transcribeSession
        )
        do {
            let decoded = try JSONDecoder().decode(WhisperResponse.self, from: data)
            let text = decoded.text ?? ""
            Log.llm.info("← dictate OK len=\(text.count) lang=\(decoded.language ?? "?")")
            return Transcription(text: text, segments: [], language: decoded.language)
        } catch {
            Log.llm.error("dictate decode failed: \(error.localizedDescription)")
            throw ClientError.decodingFailed(error.localizedDescription)
        }
    }

    /// A line said by the proxy's voice model: WAV bytes and the words it
    /// chose. `purpose` picks the model — an acknowledgement has to land fast,
    /// an answer has to sound like somebody — and `question` gives the answer
    /// its context.
    func speak(text: String, question: String, language: String, purpose: String) async throws -> SpokenLine {
        Log.llm.info("→ speak via proxy chars=\(text.count) lang=\(language) purpose=\(purpose)")
        let request = SpeakRequest(text: text, question: question, language: language, purpose: purpose)
        let data = try await postToProxyWithRetry(body: JSONEncoder().encode(ProxyEnvelope(kind: "speak", payload: request)))
        do {
            let answer = try JSONDecoder().decode(SpeakAnswer.self, from: data)
            guard let audio = Data(base64Encoded: answer.audio), !audio.isEmpty else {
                throw ClientError.decodingFailed("speak returned no audio")
            }
            Log.llm.info("← speak OK bytes=\(audio.count) words=\(answer.transcript.count)")
            return SpokenLine(audio: audio, transcript: answer.transcript)
        } catch let error as ClientError {
            throw error
        } catch {
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
    ///
    /// A batch that fails must not take the rest of the session with it. An
    /// hour-long meeting is ~30 sequential batches, and this used to `throw` out
    /// of the loop on the first 546 — leaving the opening minutes indexed and
    /// the substance of the meeting missing forever, which single-session
    /// retrieval then answered from as if it were the whole transcript.
    /// Every batch is attempted, the failures are retried once, and the error
    /// only surfaces after that — except for the errors no batch can survive
    /// (lapsed plan, signed out, build too old), which end the run immediately.
    /// Tolerating those would turn one 403 into two per batch, ~60 doomed calls
    /// for an hour-long session.
    func indexSession(meetingID: UUID, chunks: [String]) async throws {
        let total = chunks.count
        guard total > 0 else { return }
        Log.llm.info("→ index via proxy meeting=\(meetingID.uuidString) chunks=\(total) batch=\(Self.indexBatchSize)")
        var failedBases: [Int] = []
        for base in stride(from: 0, to: total, by: Self.indexBatchSize) {
            let landed = try await sendIndexBatch(meetingID: meetingID, chunks: chunks, base: base, total: total)
            if !landed { failedBases.append(base) }
        }
        var stillFailed = 0
        for base in failedBases {
            let landed = try await sendIndexBatch(meetingID: meetingID, chunks: chunks, base: base, total: total)
            if !landed { stillFailed += 1 }
        }
        guard stillFailed == 0 else {
            let missing = min(stillFailed * Self.indexBatchSize, total)
            throw ClientError.indexIncomplete(indexed: total - missing, total: total)
        }
    }

    /// True for the errors that make every remaining batch pointless: retrying
    /// can't clear them and the user has to act (or already has).
    private static func endsIndexing(_ error: ClientError) -> Bool {
        switch error {
        case .entitlementRequired, .meetingLimitReached, .meetingBlocked, .unauthenticated, .updateRequired,
             .deviceConflict:
            true
        case .requestFailed, .emptyResponse, .decodingFailed, .networkFailed, .indexIncomplete:
            false
        }
    }

    private func sendIndexBatch(meetingID: UUID, chunks: [String], base: Int, total: Int) async throws -> Bool {
        struct Payload: Encodable {
            let meeting_id: UUID
            let chunks: [String]
            let base_idx: Int
            let total: Int
        }
        let upper = min(base + Self.indexBatchSize, total)
        do {
            let payload = Payload(meeting_id: meetingID, chunks: Array(chunks[base ..< upper]), base_idx: base, total: total)
            let body = try JSONEncoder().encode(ProxyEnvelope(kind: "index", payload: payload))
            _ = try await postToProxyWithRetry(body: body)
            return true
        } catch let error as ClientError where Self.endsIndexing(error) {
            Log.llm.error("index abandoned at batch \(base) of \(total): \(error.localizedDescription)")
            throw error
        } catch {
            Log.llm.error("index batch \(base)–\(upper) of \(total) failed: \(error.localizedDescription)")
            return false
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
    ) async -> (standalone: String, hyde: String?, aboutScreen: Bool, needsSessions: Bool, screenTerms: [String]) {
        struct HyDEResult: Decodable {
            let standalone_query: String
            let hypothetical_answer: String
            let screen_terms: [String]?
            /// Absent on an older response; true then, because answering from
            /// the recordings when they weren't needed is a wasted search, and
            /// skipping them when they were needed is a wrong answer.
            let needs_sessions: Bool?
            /// Absent on older responses and on a model that ignores the field;
            /// false then, which is the safe default — no screen context rather
            /// than screen context on a question that didn't ask for it.
            let about_screen: Bool?
        }
        let (system, user) = PromptLibrary.buildHyDE(
            history: history,
            query: query,
            language: language,
            personalContext: personalContext
        )
        do {
            let result = try await completeJSON(
                system: system,
                user: user,
                as: HyDEResult.self,
                primaryModel: utilityModel
            )
            let standalone = result.standalone_query.trimmingCharacters(in: .whitespacesAndNewlines)
            let hyde = result.hypothetical_answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                standalone.isEmpty ? query : standalone,
                hyde.isEmpty ? nil : hyde,
                result.about_screen ?? false,
                result.needs_sessions ?? true,
                (result.screen_terms ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            )
        } catch {
            Log.llm.error("query prep failed (using raw query): \(error.localizedDescription)")
            return (query, nil, false, true, [])
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
    ) async throws -> KnowledgeHits {
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
        // `concepts` is absent from a proxy that predates the knowledge layer
        // and empty while reading ships dark — both decode to the same nothing.
        struct Wrapper: Decodable {
            let matches: [RetrievedChunk]
            let concepts: [RetrievedConcept]?
        }
        do {
            let decoded = try JSONDecoder().decode(Wrapper.self, from: data)
            return KnowledgeHits(chunks: decoded.matches, concepts: decoded.concepts ?? [])
        } catch {
            throw ClientError.decodingFailed(error.localizedDescription)
        }
    }

    /// Asks the proxy to distill a finished session into concepts. Server-side
    /// end to end: the function reads the transcript and the session's
    /// entities itself, so the call carries nothing but the id.
    func distill(meetingID: UUID) async throws -> DistillCounts {
        struct Payload: Encodable {
            let meeting_id: String
        }
        let body = try JSONEncoder().encode(
            ProxyEnvelope(kind: "distill", payload: Payload(meeting_id: meetingID.uuidString))
        )
        let data = try await postToProxyWithRetry(body: body)
        do {
            return try JSONDecoder().decode(DistillCounts.self, from: data)
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

    /// Asks the server to admit one new recording under `meetingID`. This is the
    /// allowance check: it happens once, before any audio exists, so an active
    /// meeting is never interrupted by it.
    func startMeetingLease(meetingID: UUID) async throws {
        let data = try await postToProxyWithRetry(
            body: Self.meetingLifecycleEnvelope(kind: "meeting_start", meetingID: meetingID)
        )
        struct Response: Decodable {
            let granted: Bool
            let meetingID: UUID

            enum CodingKeys: String, CodingKey {
                case granted
                case meetingID = "meeting_id"
            }
        }
        do {
            let response = try JSONDecoder().decode(Response.self, from: data)
            guard response.granted, response.meetingID == meetingID else {
                throw ClientError.decodingFailed("Meeting lease response did not match the request")
            }
        } catch let error as ClientError {
            throw error
        } catch {
            throw ClientError.decodingFailed(error.localizedDescription)
        }
    }

    /// Frees the slot at End. Best-effort on purpose: the lease is short-lived
    /// and renewed by use, so a lost call costs minutes, never hours.
    func endMeetingLease(meetingID: UUID) async {
        do {
            _ = try await postToProxyWithRetry(
                body: Self.meetingLifecycleEnvelope(kind: "meeting_end", meetingID: meetingID)
            )
        } catch {
            Log.llm.error("meeting_end failed (lease expires server-side): \(error.localizedDescription)")
        }
    }

    nonisolated static func meetingLifecycleEnvelope(kind: String, meetingID: UUID) throws -> Data {
        struct Payload: Encodable { let meeting_id: UUID }
        return try JSONEncoder().encode(ProxyEnvelope(kind: kind, payload: Payload(meeting_id: meetingID)))
    }

    // MARK: - Transport

    /// Wraps `postToProxy` with exponential-backoff retries on transient
    /// errors (5xx, 429, URLError). 429s in particular were dropping ~30% of
    /// Whisper chunks on the OpenRouter free tier, which is what made the
    /// "Suggest reply" answers go stale mid-meeting.
    private func postToProxyWithRetry(body: Data, using session: URLSession? = nil) async throws -> Data {
        let maxAttempts = 3
        var lastError: ClientError = .emptyResponse
        for attempt in 0 ..< maxAttempts {
            do {
                return try await postToProxy(body: body, using: session)
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
        request.setValue(AppVersion.platform, forHTTPHeaderField: "x-app-platform")
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

    /// Server-side routing can substitute a different model than the one asked
    /// for; the proxy stamps the substitute on the response and sends nothing
    /// when it left the choice alone. Without this the log only ever shows what
    /// we requested, which reads as "the change didn't apply" when it did.
    private func logRoutedModel(_ http: HTTPURLResponse) {
        guard let routed = http.value(forHTTPHeaderField: "x-nod-model-routed") else { return }
        Log.llm.info("chat routed to model=\(routed)")
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
    nonisolated static func proxyErrorCode(_ data: Data) -> String? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parsed["error"] as? String
    }

    nonisolated static func meetingBlockedMessage(_ code: String?) -> String {
        switch code {
        case "meeting_already_active":
            "Another recording is still running. Stop it before starting a new one."
        case "meeting_lease_ended":
            "That meeting has already finished."
        default:
            "Couldn't start recording just now. Please try again."
        }
    }

    private static func isEntitlementError(_ data: Data) -> Bool {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = parsed["error"] as? String else { return false }
        return error == "entitlement_required" || error == "feature_required"
    }

    private func postToProxy(body: Data, using session: URLSession? = nil) async throws -> Data {
        let request = try await makeProxyRequest(body: body)
        let session = session ?? self.session

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
        logRoutedModel(http)
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
        if http.statusCode == 403, Self.proxyErrorCode(data) == "meeting_limit_reached" {
            throw ClientError.meetingLimitReached
        }
        // 423 Locked is the lease's own refusal. It must never be confused with
        // 409 (single-device lock), which signs the user out.
        if http.statusCode == 423 {
            throw ClientError.meetingBlocked(Self.meetingBlockedMessage(Self.proxyErrorCode(data)))
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

private struct SpeakRequest: Encodable {
    let text: String
    let question: String
    let language: String
    let purpose: String
}

private struct SpeakAnswer: Decodable {
    let audio: String
    let transcript: String
}

extension LLMProxyClient {
    /// A short-lived credential for a live voice session: the client holds a
    /// WebSocket to OpenAI's Realtime API directly with this, never the real
    /// key — the one call in this file that hands the caller something it
    /// then uses without the proxy in the loop for the rest of the exchange.
    func mintRealtimeToken(language: String?) async throws -> RealtimeCredentials {
        let bodyData = try JSONEncoder().encode(
            ProxyEnvelope(kind: "realtime_token", payload: RealtimeTokenRequest(language: language))
        )
        Log.llm.info("→ realtime_token via proxy lang=\(language ?? "auto")")
        let data = try await postToProxyWithRetry(body: bodyData)
        do {
            let answer = try JSONDecoder().decode(RealtimeTokenAnswer.self, from: data)
            Log.llm.info("← realtime_token OK model=\(answer.model) voice=\(answer.voice)")
            return RealtimeCredentials(clientSecret: answer.client_secret, model: answer.model, voice: answer.voice)
        } catch let error as ClientError {
            throw error
        } catch {
            throw ClientError.decodingFailed(error.localizedDescription)
        }
    }
}

private struct RealtimeTokenRequest: Encodable {
    let language: String?
}

private struct RealtimeTokenAnswer: Decodable {
    let client_secret: String
    let model: String
    let voice: String
}

private struct DictationRequest: Encodable {
    let model: String
    let input_audio: TranscriptionRequest.InputAudio
    let temperature: Double?
    let response_format: String?
}

private struct TranscriptionRequest: Encodable {
    struct InputAudio: Encodable {
        let data: String
        let format: String
    }

    let meeting_id: UUID
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
        meeting_id: UUID,
        model: String,
        input_audio: InputAudio,
        language: String? = nil,
        prompt: String? = nil,
        temperature: Double? = nil,
        response_format: String? = nil,
        timestamp_granularities: [String]? = nil
    ) {
        self.meeting_id = meeting_id
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

struct SpokenLine {
    let audio: Data
    let transcript: String
}

struct RealtimeCredentials {
    let clientSecret: String
    let model: String
    let voice: String
}

struct TranscriptionSegment {
    let text: String
    let avgLogprob: Double?
    let noSpeechProb: Double?
    let compressionRatio: Double?
    /// Seconds from the start of the submitted chunk. Present whenever the
    /// provider honored `verbose_json`; diarization uses them to notice that one
    /// VAD chunk holds two voices.
    let start: Double?
    let end: Double?

    /// Where this segment sits inside its chunk, or nil when the provider gave
    /// no timings or gave a degenerate (non-advancing) pair.
    var range: Range<TimeInterval>? {
        guard let start, let end, end > start else { return nil }
        return start ..< end
    }
}

private struct ChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        /// nil on an assistant turn that only requested tools — the provider
        /// rejects `""` there but accepts an absent field.
        let content: String?
        var tool_calls: [ChatToolCall]?
        var tool_call_id: String?

        init(role: String, content: String?, tool_calls: [ChatToolCall]? = nil, tool_call_id: String? = nil) {
            self.role = role
            self.content = content
            self.tool_calls = tool_calls
            self.tool_call_id = tool_call_id
        }
    }

    let model: String
    let models: [String]?
    let messages: [Message]
    var tools: [ChatToolPayload]?
    let provider: ProviderPreference?
    let response_format: ResponseFormat?
    let temperature: Double?
    let stream: Bool?
    /// Opt-in prompt caching. Set only for the multi-turn Q&A chat, which
    /// re-sends the same transcript/recap system prefix on every turn — so
    /// caching it pays off (turn 1 writes, later turns read). Left nil for
    /// single-shot generation (summary/title/recap/entities), where a marked
    /// prefix would be a cache write that's never read, i.e. a net surcharge.
    /// The proxy reads this flag, applies the provider cache_control marker,
    /// and strips the field before forwarding upstream. nil is omitted from JSON.
    let cache_prompt: Bool?
    /// OpenRouter's unified reasoning switch, sent only to turn it off — see
    /// `reasoning(for:)`. nil is omitted from the JSON, leaving the model's
    /// own default alone.
    let reasoning: Reasoning?
    /// Which of the four routing categories this call belongs to — derived
    /// from which model property resolved `model` above, not sent by the
    /// caller. Every single-shot generation call (summary/title/recap/
    /// entities) has looked identical to the proxy until now; this is the
    /// first thing that lets it tell them apart. The proxy logs/records it
    /// and strips it before forwarding upstream, same as `cache_prompt`.
    let task: String?
}

private struct Reasoning: Encodable {
    let enabled: Bool
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
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}

/// One SSE chunk of a streamed chat completion. `choices` is empty on the
/// terminal usage-only chunk and `delta.content` is nil on the role-priming
/// first chunk — both decode cleanly and yield nothing.
private struct StreamChunk: Decodable {
    /// A tool call arrives split across chunks: the first carries `id` and the
    /// function name, later ones append to `arguments` a few characters at a
    /// time. `index` is what ties the fragments together when the model asks for
    /// several at once.
    struct ToolCallDelta: Decodable {
        struct Function: Decodable {
            let name: String?
            let arguments: String?
        }

        let index: Int
        let id: String?
        let function: Function?
    }

    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let tool_calls: [ToolCallDelta]?
        }

        let delta: Delta
    }

    let choices: [Choice]
}

/// Reassembles streamed tool-call fragments into whole calls.
private struct ToolCallAccumulator {
    private struct Partial {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private var byIndex: [Int: Partial] = [:]

    mutating func absorb(_ deltas: [StreamChunk.ToolCallDelta]) {
        for delta in deltas {
            var partial = byIndex[delta.index] ?? Partial()
            if let id = delta.id { partial.id = id }
            if let name = delta.function?.name { partial.name = name }
            if let arguments = delta.function?.arguments { partial.arguments += arguments }
            byIndex[delta.index] = partial
        }
    }

    /// Only calls that named a function survive — a fragment with arguments but
    /// no name is a truncated stream, not a request we can honour.
    func calls() -> [ChatToolCall] {
        byIndex
            .sorted { $0.key < $1.key }
            .compactMap { _, partial in
                guard !partial.name.isEmpty else { return nil }
                return ChatToolCall(
                    id: partial.id,
                    type: "function",
                    function: .init(name: partial.name, arguments: partial.arguments)
                )
            }
    }
}
