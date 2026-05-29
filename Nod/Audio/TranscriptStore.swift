import Foundation
import AVFoundation
import Combine

enum TranscriptSource: String {
    case me
    case them

    var label: String {
        switch self {
        case .me: return "Me"
        case .them: return "Them"
        }
    }

    var emoji: String {
        switch self {
        case .me: return "🎙"
        case .them: return "🔊"
        }
    }
}

struct TranscriptEntry: Identifiable, Equatable {
    let id = UUID()
    let source: TranscriptSource
    let text: String
    let timestamp: Date
}

final class TranscriptStore: ObservableObject {
    @Published private(set) var entries: [TranscriptEntry] = []
    @Published private(set) var liveMe: String = ""
    @Published private(set) var liveThem: String = ""
    @Published private(set) var lastSource: TranscriptSource?
    @Published private(set) var lastError: String?

    private let mic: WhisperTranscriber
    private let system: WhisperTranscriber

    init(client: OpenRouterClient, language: LanguagePreference) {
        self.mic = WhisperTranscriber(source: .me, client: client)
        self.system = WhisperTranscriber(source: .them, client: client)

        // Each chunk reads the current language at flush time, so toggling the
        // language during a meeting takes effect on the very next chunk.
        let provider: () -> String = { [weak language] in
            language?.currentWhisperCode() ?? "en"
        }
        self.mic.languageProvider = provider
        self.system.languageProvider = provider

        self.mic.onFinal = { [weak self] text, source in
            self?.handleFinal(text: text, source: source)
        }
        self.mic.onFailure = { [weak self] message, source in
            self?.handleFailure(message: message, source: source)
        }
        self.system.onFinal = { [weak self] text, source in
            self?.handleFinal(text: text, source: source)
        }
        self.system.onFailure = { [weak self] message, source in
            self?.handleFailure(message: message, source: source)
        }
    }

    func start() async {
        Log.stt.info("TranscriptStore.start() — Whisper (mic + system)")
        DispatchQueue.main.async {
            self.entries = []
            self.liveMe = ""
            self.liveThem = ""
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
            self.lastError = nil
        }
    }

    func appendMicBuffer(_ buffer: AVAudioPCMBuffer) {
        mic.append(buffer)
    }

    func appendSystemBuffer(_ buffer: AVAudioPCMBuffer) {
        system.append(buffer)
    }

    /// Force-flush both transcribers and append the results synchronously
    /// on MainActor so `fullContext` is fresh by the time this returns.
    func flushPending() async {
        async let me = mic.flushPending()
        async let them = system.flushPending()
        let (meText, themText) = await (me, them)

        await MainActor.run {
            let now = Date()
            if let text = meText {
                self.appendDeduped(text: text, source: .me, timestamp: now)
            }
            if let text = themText {
                self.appendDeduped(text: text, source: .them, timestamp: now)
            }
            self.lastError = nil
        }
    }

    var fullContext: String { recentContext(maxEntries: .max) }

    /// Last `maxEntries` finalised entries plus live partials, joined into the
    /// same `[Me]:` / `[Them]:` text the LLM expects. Used by mid-call cards
    /// (`hero`, `followUp`) whose prompts only need the recent window — sending
    /// the entire transcript on a long meeting balloons input tokens without
    /// improving answer quality. `maxEntries: .max` degrades to the full
    /// history (`fullContext`).
    func recentContext(maxEntries: Int) -> String {
        var lines: [String] = []
        for entry in entries.suffix(maxEntries) {
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

    private func handleFinal(text: String, source: TranscriptSource) {
        DispatchQueue.main.async {
            self.appendDeduped(text: text, source: source, timestamp: Date())
            self.lastError = nil
        }
    }

    // MARK: - Cross-source dedup

    /// Whisper transcribes mic and system audio independently; when the
    /// user is on speakers (no headphones), the mic re-captures whatever
    /// the system is playing → near-identical text appears under both
    /// ME and THEM within a second or two ("acoustic bleed").
    ///
    /// Strategy: when a new entry's text overlaps heavily (Jaccard ≥ 0.7
    /// on word sets) with a recent entry from the OTHER source within an
    /// 8-second window, treat them as the same utterance. THEM always
    /// wins (system audio has no acoustic path → cleaner) — either the
    /// existing ME row is replaced with the cleaner THEM text, or the
    /// incoming ME duplicate is dropped.
    ///
    /// When both sides genuinely overlap (different speakers, different
    /// content), Jaccard stays low and both rows survive.
    private func appendDeduped(text: String, source: TranscriptSource, timestamp: Date) {
        let cutoff = timestamp.addingTimeInterval(-Self.dedupWindowSeconds)
        for (idx, existing) in entries.enumerated().reversed() {
            guard existing.timestamp >= cutoff else { continue }
            guard existing.source != source else { continue }
            guard Self.textSimilarity(existing.text, text) >= Self.dedupSimilarityThreshold else { continue }

            switch (source, existing.source) {
            case (.them, .me):
                Log.stt.info("dedup: replaced ME bleed with cleaner THEM ('\(text.prefix(48))…')")
                entries[idx] = TranscriptEntry(source: .them, text: text, timestamp: timestamp)
                lastSource = .them
            case (.me, .them):
                Log.stt.info("dedup: dropped ME bleed of existing THEM ('\(text.prefix(48))…')")
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

    private static func textSimilarity(_ a: String, _ b: String) -> Double {
        let setA = wordSet(a)
        let setB = wordSet(b)
        if setA.isEmpty || setB.isEmpty { return 0 }
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        return Double(intersection) / Double(union)
    }

    private static func wordSet(_ text: String) -> Set<String> {
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
