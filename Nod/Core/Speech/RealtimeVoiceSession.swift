import AppKit
import AVFoundation
import Foundation

/// A live spoken conversation: one WebSocket, held by this Mac, straight to
/// OpenAI's Realtime API. The mic streams out as it's captured; the answer
/// streams back and plays as it arrives, and talking over it cuts it off —
/// there is no clip, no round trip per question, just an open line.
///
/// The proxy's part ends the moment it hands over the short-lived credential
/// (`LLMProxyClient.mintRealtimeToken`); everything after that — the model,
/// the voice, the persona — was baked into that credential server-side, so
/// this class carries no secret and no prompt of its own.
@MainActor
final class RealtimeVoiceSession: NSObject {
    enum State: Equatable {
        case idle
        case connecting
        case listening
        case userSpeaking
        /// `ask_nod` is running — a real search, seconds long, with nothing to
        /// play yet. Without this the display kept showing whatever it last
        /// showed (usually "Listening…", read during a tool call as "it heard
        /// nothing and gave up"), because the WebSocket itself has nothing to
        /// say about a function call still in flight.
        case thinking
        /// The model's audio is playing; the words said so far, as they arrive.
        case responding(String)
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((State) -> Void)?

    private let llmClient: LLMProxyClient
    /// Answers `ask_nod` calls with Nod's own grounded pipeline — the exact
    /// one a typed or held-key question already goes through. This class
    /// never reads the account's data itself; it only relays the question out
    /// and the finished text back in.
    private let askNod: (String) async -> String
    private var socket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    /// Bumped on every `stop()`, so a receive loop or mic callback still
    /// unwinding from the last session can't touch the next one's state.
    private var generation = 0

    // Two engines, deliberately — do not merge these into one and do not call
    // `setVoiceProcessingEnabled` on either. Both were tried, together, to
    // stop the model hearing its own voice through the speakers and cutting
    // itself off: one shared engine lets Apple's echo canceller work, but it
    // also routes the model's playback through that same processing, which
    // came out compressed and telephony-like — confirmed audibly worse.
    // `isModelSpeaking` below fixes the same echo problem without touching
    // the audio at all, so the voice stays exactly what OpenAI sends.
    private var micEngine: AVAudioEngine?
    private let micQueue = DispatchQueue(label: "nod.realtime.mic", qos: .userInteractive)
    private var micEncoder: MicEncoder?

    private var playbackEngine: AVAudioEngine?
    private var playbackNode: AVAudioPlayerNode?
    /// Gates the mic while true: nothing captured during this window reaches
    /// the server, so the model's own voice can never reach the server's VAD
    /// and be mistaken for a barge-in. Talking over the assistant still
    /// interrupts it — `BargeIn` below listens for a voice that stands well
    /// above the speaker's bleed and opens the gate on it.
    private var isModelSpeaking = false
    private let bargeIn = BargeIn()
    /// Buffers handed to `playbackNode` that haven't finished playing yet.
    /// `response.done` means the server stopped *generating* — audio arrives
    /// well ahead of real time, so a several-second answer can still have
    /// seconds of it queued at the speaker when that event lands. Closing the
    /// mic gate on `response.done` alone reopened it while the assistant's
    /// own voice was still audibly playing; the tail bled into the mic,
    /// server VAD read it as the user talking, and — with server VAD's
    /// default `create_response: true` — that started an unprompted new
    /// turn. The gate now stays shut until every queued buffer has actually
    /// finished (see `enqueuePlayback`'s completion handler).
    private var pendingPlaybackBuffers = 0
    /// Set on `response.done`; read by the last buffer's completion handler
    /// to know the mic gate should reopen the moment it fires. Split from
    /// `isModelSpeaking` because the server can say "done" before the last
    /// buffer has finished playing.
    private var serverResponseDone = false
    /// True for the whole `ask_nod` round trip — the mic stays open during
    /// it (nothing is playing, so nothing needs gating), and a stray sound
    /// the server's VAD reads as a word or two used to cost the display: the
    /// unconditional `speech_stopped` handler dropped straight back to
    /// `.listening`, stomping the `.thinking` this flag now restores instead.
    private var toolCallInFlight = false
    /// Broader than `isModelSpeaking`: true for any response the server is
    /// generating, audio or not — including the ones server VAD creates on
    /// its own between `speech_stopped` and the app ever hearing a word back.
    /// `handleToolCall`'s own `response.create` collided with exactly one of
    /// those (logged as "already has an active response in progress") when a
    /// stray utterance during an `ask_nod` wait triggered an auto-response
    /// this class had no other way to know about. Reset on `response.done`.
    private var hasActiveResponse = false
    /// Transcript deltas arrive faster than a screen redraws — several within
    /// one SwiftUI frame is normal for a live stream. Coalescing them here
    /// keeps `state` to at most one publish per flush, rather than pushing a
    /// `@Published` write (and the pill's own re-render) per word.
    private var pendingTranscript: String?
    private var transcriptFlushTask: Task<Void, Never>?

    /// A live session runs until this fires or the person ends it — the
    /// audio itself is billed per minute, and nothing upstream caps how long
    /// a connected session may stay open once started.
    private static let maxSessionSeconds: Double = 15 * 60
    private var sessionLimit: Task<Void, Never>?

    private static let sampleRate: Double = 24_000

    private static let pcmFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true) else {
            fatalError("16-bit mono PCM at 24 kHz is a format every macOS can describe")
        }
        return format
    }()

    private static let playbackFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            fatalError("mono Float32 at 24 kHz is a format every macOS can describe")
        }
        return format
    }()

    init(llmClient: LLMProxyClient, askNod: @escaping (String) async -> String) {
        self.llmClient = llmClient
        self.askNod = askNod
    }

    /// Whether the key's next tap should mean "end this" rather than "start
    /// one" — true for everything except idle and a failure already shown.
    /// A failure is display-only from here on: `state` reports it once so the
    /// pill can say why, but the session itself is already torn down (every
    /// path that sets `.failed` calls `teardown()` first), so the next tap
    /// must be free to try again rather than being swallowed as "end it".
    var isActive: Bool {
        switch state {
        case .idle, .failed: false
        case .connecting, .listening, .userSpeaking, .thinking, .responding: true
        }
    }

    /// `name` is who the voice is talking to, so it can greet and refer to
    /// them; nothing else about the person reaches the live model directly.
    func start(language: AppLanguage?, name: String? = nil) async {
        guard state == .idle else { return }
        state = .connecting
        let generation = generation
        do {
            let credentials = try await llmClient.mintRealtimeToken(language: language?.rawValue, name: name)
            guard generation == self.generation, state == .connecting else { return }
            try connect(credentials: credentials)
            try startMicrophone()
            try startPlayback()
            state = .listening
            Log.llm.info("realtime: session started model=\(credentials.model) voice=\(credentials.voice)")
            sessionLimit = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.maxSessionSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch {
            Log.llm.error("realtime: could not start — \(error.localizedDescription)")
            guard generation == self.generation else { return }
            teardown()
            state = .failed("Couldn't start the live session")
        }
    }

    func stop() {
        guard state != .idle else { return }
        generation += 1
        teardown()
        state = .idle
    }

    private func teardown() {
        sessionLimit?.cancel()
        sessionLimit = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        urlSession = nil
        stopMicrophone()
        stopPlayback()
        cancelTranscriptFlush()
        toolCallInFlight = false
    }

    private func cancelTranscriptFlush() {
        transcriptFlushTask?.cancel()
        transcriptFlushTask = nil
        pendingTranscript = nil
    }

    /// Buffers a transcript update and publishes it at most once per short
    /// window, so a burst of deltas costs one pill redraw, not one each.
    private func scheduleTranscriptFlush(_ text: String) {
        pendingTranscript = text
        guard transcriptFlushTask == nil else { return }
        let generation = generation
        transcriptFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard let self, generation == self.generation else { return }
            transcriptFlushTask = nil
            guard let text = pendingTranscript else { return }
            pendingTranscript = nil
            guard case .responding = state else { return }
            state = .responding(text)
        }
    }

    // MARK: - Socket

    private func connect(credentials: RealtimeCredentials) throws {
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=\(credentials.model)") else {
            throw ClientAudioError.badURL
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.clientSecret)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        urlSession = session
        socket = task
        task.resume()
        receive(generation: generation)
    }

    private func receive(generation: Int) {
        socket?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, generation == self.generation else { return }
                switch result {
                case let .success(message):
                    handle(message)
                    receive(generation: generation)
                case let .failure(error):
                    Log.llm.error("realtime: socket error — \(error.localizedDescription)")
                    teardown()
                    state = .failed("Connection lost")
                }
            }
        }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { return }
        socket?.send(.string(text)) { error in
            if let error {
                Log.llm.error("realtime: send failed — \(error.localizedDescription)")
            }
        }
    }

    private var currentTranscript: String {
        if case let .responding(text) = state { return text }
        return ""
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case let .string(text) = message,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return }
        switch type {
        case "response.created":
            hasActiveResponse = true
        case "response.output_audio.delta":
            guard let base64 = object["delta"] as? String, let bytes = Data(base64Encoded: base64) else { return }
            if !isModelSpeaking {
                isModelSpeaking = true
                serverResponseDone = false
                state = .responding("")
                micQueue.async { [bargeIn] in bargeIn.reset() }
            }
            enqueuePlayback(pcm16: bytes)
        case "response.output_audio_transcript.delta":
            let delta = object["delta"] as? String ?? ""
            let soFar = (pendingTranscript ?? currentTranscript) + delta
            scheduleTranscriptFlush(soFar)
        case "response.function_call_arguments.done":
            guard let callID = object["call_id"] as? String, let name = object["name"] as? String else { return }
            handleToolCall(name: name, callID: callID, argumentsJSON: object["arguments"] as? String ?? "{}")
        case "response.done":
            hasActiveResponse = false
            serverResponseDone = true
            // No audio ever played for this response (a function call, or a
            // turn cut short) — nothing queued means nothing to wait for.
            if pendingPlaybackBuffers == 0 { finishSpeaking() }
        case "input_audio_buffer.speech_started":
            // Local playback has to be cleared here regardless — audio
            // already queued on this Mac keeps playing until told otherwise.
            // The server-side cancel is the other half: without it, the
            // response we just stopped playing is still "in progress" from
            // the server's own point of view, and the very next
            // `response.create` (a tool call handing back its answer, or the
            // next turn) is refused with "already has an active response in
            // progress" — logged, but otherwise silent, so the reply it was
            // trying to give is just lost.
            if isModelSpeaking {
                flushPlayback()
                pendingPlaybackBuffers = 0
                isModelSpeaking = false
                cancelTranscriptFlush()
            }
            if hasActiveResponse {
                send(["type": "response.cancel"])
                hasActiveResponse = false
            }
            state = .userSpeaking
        case "input_audio_buffer.speech_stopped":
            if state == .userSpeaking { state = toolCallInFlight ? .thinking : .listening }
        case "error":
            let detail = (object["error"] as? [String: Any])?["message"] as? String ?? "unknown"
            // `response.cancel` sent above races the server's own bookkeeping
            // — it may already have closed out the response by the time the
            // cancel lands, which comes back as this exact error. Harmless:
            // the thing we asked to stop had already stopped.
            guard !detail.localizedCaseInsensitiveContains("no active response") else { return }
            Log.llm.error("realtime: server error — \(detail)")
            // The socket often stays open after a non-fatal error (a bad turn,
            // a moderation refusal) — nothing else here would ever notice, and
            // the pill would sit on "Listening…" over a session that has
            // quietly stopped doing anything.
            teardown()
            state = .failed("That didn't go through — try again")
        default:
            break
        }
    }

    /// The person spoke over the answer: what is queued at the speaker is
    /// cut, the server is told to stop, and the gate opens so the words that
    /// follow reach it. The server's own `speech_started` then does its part.
    private func interruptModel() {
        flushPlayback()
        pendingPlaybackBuffers = 0
        isModelSpeaking = false
        cancelTranscriptFlush()
        if hasActiveResponse {
            send(["type": "response.cancel"])
            hasActiveResponse = false
        }
        state = .userSpeaking
    }

    /// The mic gate actually reopens here — once the server says a response
    /// is done AND every buffer it sent has finished playing (see
    /// `pendingPlaybackBuffers`), never on `response.done` alone.
    private func finishSpeaking() {
        isModelSpeaking = false
        cancelTranscriptFlush()
        if state != .idle { state = .listening }
    }

    private func handleToolCall(name: String, callID: String, argumentsJSON: String) {
        switch name {
        case "ask_nod":
            handleAskNod(callID: callID, argument: stringArgument("question", from: argumentsJSON))
        case "open_url":
            handleOpenURL(callID: callID, argument: stringArgument("url", from: argumentsJSON))
        case "open_app":
            handleOpenApp(callID: callID, argument: stringArgument("name", from: argumentsJSON))
        default:
            break
        }
    }

    private func stringArgument(_ key: String, from argumentsJSON: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] as? String
        else { return "" }
        return value
    }

    /// Runs the account's own knowledge pipeline for a question the live
    /// model asked for, and hands the answer back so it can speak it. The
    /// model keeps talking about something else while this runs — a search
    /// is not instant, and a live conversation does not stop to wait quietly.
    private func handleAskNod(callID: String, argument question: String) {
        let generation = generation
        state = .thinking
        toolCallInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let answer = question.isEmpty ? "The question didn't come through — ask again." : await askNod(question)
            guard generation == self.generation else { return }
            toolCallInFlight = false
            respondToTool(callID: callID, output: answer)
        }
    }

    /// `open_url`/`open_app` both resolve and act synchronously — nothing
    /// here is worth a "Thinking…" pill for.

    private func handleOpenURL(callID: String, argument raw: String) {
        guard let url = VoiceOpenActions.validatedURL(raw) else {
            respondToTool(callID: callID, output: "That wasn't a link Nod can open.")
            return
        }
        NSWorkspace.shared.open(url)
        respondToTool(callID: callID, output: "Opened.")
    }

    private func handleOpenApp(callID: String, argument name: String) {
        guard let appURL = VoiceOpenActions.resolveApplication(named: name) else {
            respondToTool(callID: callID, output: "Couldn't find an app called \"\(name)\" on this Mac.")
            return
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                respondToTool(callID: callID, output: error == nil ? "Opened." : "Couldn't open \(name).")
            }
        }
    }

    /// Hands a tool's result back to the model and lets it continue —
    /// shared by all three tools so the same server-side bookkeeping
    /// (cancelling a response the server auto-created while this ran, so it
    /// doesn't collide with the one about to be created for this answer)
    /// isn't repeated three times.
    private func respondToTool(callID: String, output: String) {
        if hasActiveResponse {
            send(["type": "response.cancel"])
            hasActiveResponse = false
        }
        send([
            "type": "conversation.item.create",
            "item": ["type": "function_call_output", "call_id": callID, "output": output]
        ])
        send(["type": "response.create"])
    }

    // MARK: - Microphone

    private func startMicrophone() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        engine.prepare()
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.pcmFormat) else {
            throw ClientAudioError.converterFailed
        }
        let encoder = MicEncoder(converter: converter, targetFormat: Self.pcmFormat)
        micEncoder = encoder
        let queue = micQueue
        let generation = generation
        let bargeIn = bargeIn
        input.installTap(onBus: 0, bufferSize: 2400, format: nil) { [weak self] buffer, _ in
            guard let copy = Self.copyBuffer(buffer) else { return }
            queue.async {
                guard let encoded = encoder.encode(copy) else { return }
                let interrupts = bargeIn.observe(level: encoded.level)
                Task { @MainActor [weak self] in
                    guard let self, generation == self.generation else { return }
                    if isModelSpeaking {
                        guard interrupts else { return }
                        interruptModel()
                    }
                    send(["type": "input_audio_buffer.append", "audio": encoded.base64])
                }
            }
        }
        try engine.start()
        micEngine = engine
    }

    private func stopMicrophone() {
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
        micEncoder = nil
    }

    /// Converts a captured buffer to 24 kHz mono PCM16 and base64-encodes it.
    /// Owns the `AVAudioConverter`, touched only from `micQueue` — the same
    /// shape `WhisperTranscriber` uses for its own cached converter.
    private final class MicEncoder: @unchecked Sendable {
        private let converter: AVAudioConverter
        private let targetFormat: AVAudioFormat

        init(converter: AVAudioConverter, targetFormat: AVAudioFormat) {
            self.converter = converter
            self.targetFormat = targetFormat
        }

        func encode(_ buffer: AVAudioPCMBuffer) -> (base64: String, level: Float)? {
            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 256
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
            var fed = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, output.frameLength > 0, let channel = output.int16ChannelData else { return nil }
            let count = Int(output.frameLength)
            let data = Data(bytes: channel[0], count: count * MemoryLayout<Int16>.size)
            var energy: Float = 0
            for index in 0 ..< count {
                let sample = Float(channel[0][index]) / Float(Int16.max)
                energy += sample * sample
            }
            return (data.base64EncodedString(), (energy / Float(count)).squareRoot())
        }
    }

    /// Hears the person over the assistant without echo cancellation.
    ///
    /// While the model speaks, the mic hears the speakers; how loudly is
    /// learned from the first moments of each answer and tracked after. A
    /// voice at the desk is several times louder than that bleed, and once
    /// it has been for a few buffers in a row this says so. Touched only
    /// from `micQueue`.
    private final class BargeIn: @unchecked Sendable {
        private var bleed: Float = 0
        private var buffers = 0
        private var loud = 0

        private static let settleBuffers = 6
        private static let ratio: Float = 4
        private static let floor: Float = 0.02
        private static let loudBuffers = 3

        /// Whether this buffer, on top of the ones before it, is the person.
        func observe(level: Float) -> Bool {
            buffers += 1
            if buffers <= Self.settleBuffers {
                bleed = max(bleed, level)
                return false
            }
            if level > max(bleed * Self.ratio, Self.floor) {
                loud += 1
                return loud >= Self.loudBuffers
            }
            loud = 0
            bleed = bleed * 0.95 + level * 0.05
            return false
        }

        func reset() {
            bleed = 0
            buffers = 0
            loud = 0
        }
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let count = Int(buffer.frameLength)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for channel in 0 ..< channels {
                dst[channel].update(from: src[channel], count: count)
            }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for channel in 0 ..< channels {
                dst[channel].update(from: src[channel], count: count)
            }
        } else {
            return nil
        }
        return copy
    }

    // MARK: - Playback

    private func startPlayback() throws {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: Self.playbackFormat)
        try engine.start()
        node.play()
        playbackEngine = engine
        playbackNode = node
    }

    private func stopPlayback() {
        playbackNode?.stop()
        playbackEngine?.stop()
        playbackEngine = nil
        playbackNode = nil
        // Not relied on for correctness — `generation` already guards every
        // completion handler — but stopping the node doesn't promise every
        // pending one actually fires, and a stale nonzero count would start
        // the next session's mic gate already (and permanently) shut.
        pendingPlaybackBuffers = 0
        serverResponseDone = false
    }

    /// Cuts whatever is queued or playing, for a barge-in. The node keeps
    /// running — only its schedule is cleared — so the next `scheduleBuffer`
    /// after this needs no re-`play()`.
    private func flushPlayback() {
        playbackNode?.stop()
        playbackNode?.play()
    }

    private func enqueuePlayback(pcm16: Data) {
        guard let node = playbackNode else { return }
        let sampleCount = pcm16.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.playbackFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let channel = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0 ..< sampleCount {
                channel[i] = Float(samples[i]) / Float(Int16.max)
            }
        }
        pendingPlaybackBuffers += 1
        let generation = generation
        // `.dataPlayedBack`, not the default `.dataConsumed` — the mic gate
        // needs to know the audio actually finished coming out of the
        // speaker, not just that this buffer was handed to the render
        // thread (which can be a second or more ahead of what's audible).
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, generation == self.generation else { return }
                pendingPlaybackBuffers = max(0, pendingPlaybackBuffers - 1)
                if pendingPlaybackBuffers == 0, serverResponseDone {
                    finishSpeaking()
                }
            }
        }
    }

    private enum ClientAudioError: Error {
        case badURL
        case converterFailed
    }
}
