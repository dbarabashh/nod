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

    /// `Me` / `Them`, or `Them N` when diarization separated more than one
    /// remote speaker. Single source of truth for both the live transcript and
    /// persisted-record rendering.
    func displayLabel(speaker: Int?, numbered: Bool) -> String {
        if self == .them, numbered, let speaker {
            return "Them \(speaker + 1)"
        }
        return label
    }
}

struct TranscriptEntry: Identifiable, Equatable {
    let id = UUID()
    let source: TranscriptSource
    let text: String
    let timestamp: Date
    /// Diarized speaker index within the `.them` stream (0-based); nil for `.me`
    /// and while diarization is unavailable. Set live, then overwritten by the
    /// global re-clustering at meeting end.
    var speaker: Int?
}

/// One Whisper-finalised chunk handed up from a `WhisperTranscriber`. Carries
/// the diarization payload for `.them`: the live speaker index plus the raw
/// voiceprint, which TranscriptStore keeps for the end-of-meeting re-cluster.
struct TranscribedChunk {
    let text: String
    let source: TranscriptSource
    let speaker: Int?
    let embedding: [Float]?
}

final class TranscriptStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var entries: [TranscriptEntry] = []
    @Published private(set) var liveMe: String = ""
    @Published private(set) var liveThem: String = ""
    @Published private(set) var lastSource: TranscriptSource?
    @Published private(set) var lastError: String?

    private let mic: WhisperTranscriber
    private let system: WhisperTranscriber

    /// Voiceprints for `.them` entries, keyed by entry id, accumulated during
    /// the meeting and re-clustered by `refineSpeakers()` at the end. Touched
    /// only on the main queue (alongside `entries`), so no locking.
    private var embeddings: [UUID: [Float]] = [:]

    init(client: OpenRouterClient, language: LanguagePreference) {
        mic = WhisperTranscriber(source: .me, client: client)
        system = WhisperTranscriber(source: .them, client: client)

        // Each chunk reads the current language at flush time, so toggling the
        // language during a meeting takes effect on the very next chunk.
        let provider: () -> String = { [weak language] in
            language?.currentWhisperCode() ?? "en"
        }
        mic.languageProvider = provider
        system.languageProvider = provider

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
            self.embeddings = [:]
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
        // Only number "Them" speakers once diarization has actually separated
        // more than one — a single remote voice reads cleaner as plain "Them".
        let themSpeakers = Set(included.compactMap { $0.source == .them ? $0.speaker : nil })
        let numbered = themSpeakers.count > 1
        var lines: [String] = []
        for entry in included {
            lines.append("[\(label(for: entry, numbered: numbered))]: \(entry.text)")
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
            self.appendDeduped(chunk: chunk, timestamp: Date())
            self.lastError = nil
        }
    }

    /// `Me` / `Them` for the live bubble + persistence, or `Them N` once more
    /// than one remote speaker is present (see `recentContext`).
    private func label(for entry: TranscriptEntry, numbered: Bool) -> String {
        entry.source.displayLabel(speaker: entry.speaker, numbered: numbered)
    }

    /// Re-cluster every `.them` voiceprint collected this meeting into globally
    /// consistent speaker labels, fixing the drift inherent in live greedy
    /// assignment. Call after `flushPending()` and before reading `fullContext`
    /// for the summary, so the LLM sees stable "Them N" attribution.
    func refineSpeakers() async {
        // Snapshot the ordered them-entry ids and their voiceprints on the main
        // queue, where `entries`/`embeddings` are mutated. Only segments that
        // produced a voiceprint are clustered — short clips are skipped at
        // capture time (their embeddings are unreliable).
        let snapshot: (themIDs: [UUID], embeddedIDs: [UUID], vectors: [[Float]])? = await MainActor.run {
            let them = entries.filter { $0.source == .them }
            guard them.count >= 2 else { return nil }
            let pairs = them.compactMap { entry -> (UUID, [Float])? in
                guard let vector = embeddings[entry.id] else { return nil }
                return (entry.id, vector)
            }
            guard pairs.count >= 2 else { return nil }
            return (them.map(\.id), pairs.map(\.0), pairs.map(\.1))
        }
        guard let snapshot else { return }

        // Run the O(n²) agglomerative clustering OFF the main thread — a long
        // meeting (hundreds of segments) would otherwise freeze the UI for
        // seconds at meeting end. `Task.detached` guarantees the hop regardless
        // of this type's isolation: relying on `refineSpeakers` being
        // nonisolated would silently regress if `TranscriptStore` ever became
        // `@MainActor` (common for an ObservableObject).
        let vectors = snapshot.vectors
        let labels = await Task.detached(priority: .userInitiated) {
            SpeakerClusterer.cluster(vectors)
        }.value
        var labelByID: [UUID: Int] = [:]
        for (index, id) in snapshot.embeddedIDs.enumerated() {
            labelByID[id] = labels[index]
        }

        await MainActor.run {
            let positionByID = Dictionary(
                entries.enumerated().map { ($1.id, $0) },
                uniquingKeysWith: { existing, _ in existing }
            )
            // Carry the last known speaker onto the embedding-less short
            // segments so they don't read as new voices.
            var lastSpeaker = labels.first ?? 0
            for id in snapshot.themIDs {
                let speaker = labelByID[id] ?? lastSpeaker
                if let idx = positionByID[id] { entries[idx].speaker = speaker }
                lastSpeaker = speaker
            }
            logSpeakerDistribution()
        }
    }

    private func logSpeakerDistribution() {
        var bySpeaker: [Int: [TranscriptEntry]] = [:]
        for entry in entries where entry.source == .them {
            guard let speaker = entry.speaker else { continue }
            bySpeaker[speaker, default: []].append(entry)
        }
        let themCount = entries.lazy.filter { $0.source == .them }.count
        Log.stt.info("diarization refine: \(bySpeaker.count) speaker(s) across \(themCount) segments")
        for speaker in bySpeaker.keys.sorted() {
            let group = bySpeaker[speaker] ?? []
            let sample = group.first.map { $0.text.split(separator: " ").prefix(6).joined(separator: " ") } ?? ""
            Log.stt.info("  speaker \(speaker + 1): \(group.count) segments — e.g. \"\(sample)…\"")
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
        let cutoff = timestamp.addingTimeInterval(-Self.dedupWindowSeconds)
        let incoming = Self.wordSet(text)
        for (idx, existing) in entries.enumerated().reversed() {
            guard existing.timestamp >= cutoff else { continue }
            guard existing.source != source else { continue }
            guard Self.isAcousticBleed(Self.wordSet(existing.text), incoming) else { continue }

            switch (source, existing.source) {
            case (.them, .me):
                Log.stt.info("dedup: replaced ME bleed with cleaner THEM ('\(text.prefix(48))…')")
                let replacement = TranscriptEntry(source: .them, text: text, timestamp: timestamp, speaker: chunk.speaker)
                embeddings.removeValue(forKey: existing.id)
                embeddings[replacement.id] = chunk.embedding
                entries[idx] = replacement
                lastSource = .them
            case (.me, .them):
                Log.stt.info("dedup: dropped ME bleed of existing THEM ('\(text.prefix(48))…')")
            default:
                break
            }
            return
        }

        let entry = TranscriptEntry(source: source, text: text, timestamp: timestamp, speaker: chunk.speaker)
        embeddings[entry.id] = chunk.embedding
        entries.append(entry)
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
