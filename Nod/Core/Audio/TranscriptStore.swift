import AVFoundation
import Combine
import Foundation

enum TranscriptSource: String {
    case me
    case them

    var label: String {
        switch self {
        case .me: "Me"
        case .them: "Them"
        }
    }

    var emoji: String {
        switch self {
        case .me: "🎙"
        case .them: "🔊"
        }
    }
}

struct TranscriptEntry: Identifiable, Equatable {
    let id = UUID()
    let source: TranscriptSource
    let text: String
    let timestamp: Date
}

/// One Whisper-finalised chunk handed up from a `WhisperTranscriber`.
struct TranscribedChunk {
    let text: String
    let source: TranscriptSource
    let timestamp: Date
}

final class TranscriptStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var entries: [TranscriptEntry] = []
    @Published private(set) var liveMe: String = ""
    @Published private(set) var liveThem: String = ""
    @Published private(set) var lastSource: TranscriptSource?
    /// Speech-onset time of the most recent confirmed utterance on either
    /// stream. Stamped from the chunk's audio-clock timestamp (not `Date()`) so
    /// Whisper latency doesn't skew it. Drives trailing-silence trimming and the
    /// forgot-to-stop watchdog; `nil` until the first utterance lands.
    @Published private(set) var lastSpeechAt: Date?
    @Published private(set) var lastError: String?

    private let mic: WhisperTranscriber
    private let system: WhisperTranscriber

    init(client: LLMProxyClient) {
        mic = WhisperTranscriber(source: .me, client: client)
        system = WhisperTranscriber(source: .them, client: client)

        mic.onFinal = { [weak self] chunk in
            self?.handleFinal(chunk)
        }
        mic.onFailure = { [weak self] message, source in
            self?.handleFailure(message: message, source: source)
        }
        system.onFinal = { [weak self] chunk in
            self?.handleFinal(chunk)
        }
        system.onFailure = { [weak self] message, source in
            self?.handleFailure(message: message, source: source)
        }
    }

    func start() async {
        Log.stt.info("TranscriptStore.start() — Whisper (mic + system)")
        DispatchQueue.main.async {
            self.entries = []
            self.liveMe = ""
            self.liveThem = ""
            self.lastSpeechAt = nil
            self.lastError = nil
        }
        await mic.start()
        await system.start()
    }

    func stop() {
        Log.stt.info("TranscriptStore.stop() — finalized entries=\(entries.count)")
        mic.stop()
        system.stop()
    }

    func clear() {
        DispatchQueue.main.async {
            self.entries = []
            self.liveMe = ""
            self.liveThem = ""
            self.lastSource = nil
            self.lastSpeechAt = nil
            self.lastError = nil
        }
    }

    func appendMicBuffer(_ buffer: AVAudioPCMBuffer) {
        mic.append(buffer)
    }

    func appendSystemBuffer(_ buffer: AVAudioPCMBuffer) {
        // The system path's mono buffer is freshly allocated per callback by
        // SampleBufferConverter and never reused — hand it over instead of
        // paying a second copy (the mic path keeps the default copy because
        // its tap buffer is engine-owned).
        system.append(buffer, copying: false)
    }

    /// Force-flush both transcribers and append the results synchronously
    /// on MainActor so `fullContext` is fresh by the time this returns.
    func flushPending() async {
        // Drain both transcribers' in-flight work so `fullContext` is complete
        // and in order by the time this returns. The VAD owns segmentation now,
        // so there's no forced-out partial text to append here.
        async let me: Void = mic.flushPending()
        async let them: Void = system.flushPending()
        _ = await (me, them)
        await MainActor.run { self.lastError = nil }
    }

    var fullContext: String {
        recentContext(maxEntries: .max)
    }

    /// Last `maxEntries` finalised entries plus live partials, joined into the
    /// same `[Me]:` / `[Them]:` text the LLM expects. Used by mid-call cards
    /// (`hero`, `followUp`) whose prompts only need the recent window — sending
    /// the entire transcript on a long meeting balloons input tokens without
    /// improving answer quality. `maxEntries: .max` degrades to the full
    /// history (`fullContext`).
    func recentContext(maxEntries: Int) -> String {
        let included = Array(entries.suffix(maxEntries))
        var lines: [String] = []
        for entry in included {
            lines.append("[\(entry.source.label)]: \(entry.text)")
        }
        // No live partials with Whisper (it's batch), but kept for forward-compat
        // in case we ever wire a streaming STT alongside.
        if !liveMe.isEmpty {
            lines.append("[Me]: \(liveMe)…")
        }
        if !liveThem.isEmpty {
            lines.append("[Them]: \(liveThem)…")
        }
        return lines.joined(separator: "\n")
    }

    var hasContent: Bool {
        !entries.isEmpty || !liveMe.isEmpty || !liveThem.isEmpty
    }

    var bubbleSnapshot: (source: TranscriptSource, text: String, isLive: Bool)? {
        if !liveMe.isEmpty { return (.me, liveMe, true) }
        if !liveThem.isEmpty { return (.them, liveThem, true) }
        if let entry = entries.last { return (entry.source, entry.text, false) }
        return nil
    }

    // MARK: - Callbacks from WhisperTranscriber

    private func handleFinal(_ chunk: TranscribedChunk) {
        DispatchQueue.main.async {
            self.appendDeduped(chunk: chunk, timestamp: chunk.timestamp)
            self.lastError = nil
        }
    }

    // MARK: - Cross-source dedup

    /// Whisper transcribes mic and system audio independently; when the
    /// user is on speakers (no headphones), the mic re-captures whatever
    /// the system is playing → near-identical text appears under both
    /// ME and THEM within a second or two ("acoustic bleed").
    ///
    /// Strategy: when a new entry's text overlaps heavily with a recent
    /// entry from the OTHER source within an 8-second window, treat them
    /// as the same utterance. THEM always wins (system audio has no
    /// acoustic path → cleaner) — either the existing ME row is replaced
    /// with the cleaner THEM text, or the incoming ME duplicate is dropped.
    ///
    /// "Overlaps heavily" means EITHER symmetric similarity (Jaccard ≥ 0.7)
    /// OR containment — the shorter line is almost entirely inside the
    /// longer one. The two Whisper passes often chunk the same utterance
    /// differently: the mic echo tacks on a few words from the next breath
    /// (e.g. "…talking about, Sarit? No, I was just saying"), which drags
    /// Jaccard under 0.7 while the lines are still near-subsets. Symmetric
    /// Jaccard misses that and the echo leaks — taking its own mis-hearings
    /// (here "sorry" → "Sarit") into the transcript. Containment catches it.
    ///
    /// When both sides genuinely overlap (different speakers, different
    /// content), neither metric fires and both rows survive.
    private func appendDeduped(chunk: TranscribedChunk, timestamp: Date) {
        let text = chunk.text
        let source = chunk.source
        // Every chunk reaching here is real detected speech (including acoustic
        // bleed, which is still someone talking) — record activity before the
        // dedup branches so a dropped ME echo still counts. Keep it monotonic.
        lastSpeechAt = max(lastSpeechAt ?? timestamp, timestamp)
        let cutoff = timestamp.addingTimeInterval(-Self.dedupWindowSeconds)
        let incoming = Self.wordSet(text)
        for (idx, existing) in entries.enumerated().reversed() {
            guard existing.timestamp >= cutoff else { continue }
            guard existing.source != source else { continue }
            guard Self.isAcousticBleed(Self.wordSet(existing.text), incoming) else { continue }

            switch (source, existing.source) {
            case (.them, .me):
                Log.stt.sensitive("dedup: replaced ME bleed with cleaner THEM ('\(text.prefix(48))…')")
                entries[idx] = TranscriptEntry(source: .them, text: text, timestamp: timestamp)
                lastSource = .them
            case (.me, .them):
                Log.stt.sensitive("dedup: dropped ME bleed of existing THEM ('\(text.prefix(48))…')")
            default:
                break
            }
            return
        }

        entries.append(TranscriptEntry(source: source, text: text, timestamp: timestamp))
        lastSource = source
    }

    private static let dedupWindowSeconds: TimeInterval = 8
    private static let dedupSimilarityThreshold: Double = 0.7
    private static let dedupContainmentThreshold: Double = 0.8
    private static let dedupMinContainmentWords: Int = 4

    static func isAcousticBleed(_ setA: Set<String>, _ setB: Set<String>) -> Bool {
        if setA.isEmpty || setB.isEmpty { return false }
        let intersection = setA.intersection(setB).count
        let union = setA.count + setB.count - intersection
        if Double(intersection) / Double(union) >= dedupSimilarityThreshold { return true }

        // Asymmetric fallback: the shorter line is a near-subset of the
        // longer one. Require a few words in the smaller set so a stray
        // "yeah" / "okay" can't latch onto an unrelated longer turn.
        let smaller = min(setA.count, setB.count)
        guard smaller >= dedupMinContainmentWords else { return false }
        return Double(intersection) / Double(smaller) >= dedupContainmentThreshold
    }

    static func wordSet(_ text: String) -> Set<String> {
        var current = ""
        var words: Set<String> = []
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { words.insert(current) }
        return words
    }

    private func handleFailure(message: String, source: TranscriptSource) {
        // Cap what surfaces to the bubble. Some failure paths (HTML 500 pages
        // from upstream Whisper providers) produce kilobyte-long bodies that
        // otherwise render as the entire transcript bubble.
        let firstLine = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message
        let trimmed = String(firstLine.prefix(160))
        DispatchQueue.main.async {
            self.lastError = "[\(source.label)] \(trimmed)"
        }
    }
}
