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

    var fullContext: String {
        var lines: [String] = []
        for entry in entries {
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
            self.entries.append(TranscriptEntry(source: source, text: text, timestamp: Date()))
            self.lastSource = source
            self.lastError = nil
        }
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
