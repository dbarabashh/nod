import AVFoundation
import Foundation

/// Nod's side of a spoken exchange: a word that it is on it the moment the
/// question is understood, then the answer — said, not read. The card's text
/// is written for eyes; the proxy's voice model is given the substance and a
/// way of speaking and says it in its own words, which come back with the
/// audio so the notch can show them.
///
/// One mouth. Everything to be said passes through one queue and one player,
/// so an acknowledgement finishes before the answer starts and nothing is
/// ever said over something else. Escape, or the next question, cuts it off.
@MainActor
final class SpokenAnswer: ObservableObject {
    private enum Line {
        case acknowledgement(question: String)
        case answer(String, question: String)
        /// Already-final, authored copy — one step of onboarding, never a
        /// reply to anything asked.
        case scripted(String)

        var isAnswer: Bool {
            if case .answer = self { return true }
            return false
        }

        var purpose: String {
            switch self {
            case .acknowledgement: "acknowledgement"
            case .answer: "answer"
            case .scripted: "narration"
            }
        }

        var text: String {
            switch self {
            case let .acknowledgement(question): question
            case let .answer(answer, _): answer
            case let .scripted(text): text
            }
        }

        var question: String {
            switch self {
            case let .acknowledgement(question), let .answer(_, question): question
            case .scripted: ""
            }
        }
    }

    /// The proxy's cap on a line; an answer is cut to fit rather than refused.
    private static let maxLineLength = 1500

    /// The words being said right now, or nil once nothing is. Drives the
    /// notch's "Speaking" state.
    var onSpeaking: ((String?) -> Void)?

    private let llmClient: LLMProxyClient
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var queue: [(Line, AppLanguage)] = []
    private var playing: Line?
    private var finish: CheckedContinuation<Void, Never>?
    /// Bumped by `stop()`, so a line still being fetched when the person
    /// moved on is dropped rather than said late.
    private var generation = 0

    init(llmClient: LLMProxyClient) {
        self.llmClient = llmClient
        synthesizer.delegate = delegateBridge
    }

    /// Only the line being said may release the wait: a cut-off utterance
    /// reports its cancellation a turn late, when the next line may already
    /// be waiting on the same continuation.
    private lazy var delegateBridge = FinishBridge { [weak self] source in
        Task { @MainActor in
            guard let self else { return }
            switch source {
            case let .player(player): if player === self.player { self.finished() }
            case let .utterance(utterance): if utterance === self.utterance { self.finished() }
            }
        }
    }

    private var utterance: AVSpeechUtterance?

    /// Said as soon as the question is understood, while the answer is still
    /// being worked out.
    func acknowledge(_ question: String, language: AppLanguage) {
        enqueue(.acknowledgement(question: question), language: language)
    }

    /// A newer answer replaces one that has not been said and cuts one that
    /// is being said — but never the acknowledgement still on its way out.
    func say(_ answer: String, asking question: String, language: AppLanguage) {
        queue.removeAll { $0.0.isAnswer }
        if playing?.isAnswer == true {
            // Whether it is playing or still being fetched: the generation
            // drops a clip that arrives late, the cut stops one that is out.
            generation += 1
            cutCurrent()
        }
        enqueue(.answer(String(answer.prefix(Self.maxLineLength)), question: question), language: language)
    }

    /// One line of pre-written copy — an onboarding step's narration. Queued
    /// like any other line, so it never talks over an acknowledgement or an
    /// answer already in flight; several steps in a row simply queue in
    /// order rather than interrupting each other.
    func sayScripted(_ text: String, language: AppLanguage) {
        enqueue(.scripted(String(text.prefix(Self.maxLineLength))), language: language)
    }

    func stop() {
        generation += 1
        queue = []
        cutCurrent()
    }

    private func enqueue(_ line: Line, language: AppLanguage) {
        queue.append((line, language))
        drain()
    }

    private func drain() {
        guard playing == nil, !queue.isEmpty else { return }
        let (line, language) = queue.removeFirst()
        playing = line
        let generation = generation
        Task { [weak self] in
            guard let self else { return }
            await voice(line, language: language, generation: generation)
            playing = nil
            if queue.isEmpty { onSpeaking?(nil) }
            drain()
        }
    }

    /// Says the line and returns once it has been said, or cut.
    private func voice(_ line: Line, language: AppLanguage, generation: Int) async {
        do {
            let spoken = try await llmClient.speak(
                text: line.text,
                question: line.question,
                language: language.rawValue,
                purpose: line.purpose
            )
            guard generation == self.generation else { return }
            let player = try AVAudioPlayer(data: spoken.audio)
            player.delegate = delegateBridge
            self.player = player
            onSpeaking?(spoken.transcript)
            Log.ui.info("spoken: \(line.purpose) in \(language.rawValue), \(spoken.transcript.count) chars via proxy voice")
            var started = false
            await untilFinished {
                started = player.play()
                if !started { finished() }
            }
            self.player = nil
            if started { return }
            Log.ui.error("spoken: the player would not start — using the system voice")
            await speakOnDevice(line, language: language)
        } catch {
            guard generation == self.generation else { return }
            Log.ui.error("spoken: proxy voice failed (\(error.localizedDescription)) — using the system voice")
            await speakOnDevice(line, language: language)
        }
    }

    /// The Mac's own voice, reading a plain rendering of the line: the answer
    /// with its marks taken off, or a fixed "one moment" for the language.
    private func speakOnDevice(_ line: Line, language: AppLanguage) async {
        guard let voice = Self.voice(for: language) else {
            Log.ui.error("spoken: no \(language.rawValue) voice installed — add one under Accessibility › Spoken Content")
            return
        }
        let text = line.isAnswer ? SpokenText.plain(line.text) : Self.fallbackAcknowledgement(language)
        guard !text.isEmpty else { return }
        onSpeaking?(text)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        self.utterance = utterance
        await untilFinished { synthesizer.speak(utterance) }
        self.utterance = nil
    }

    private func untilFinished(_ begin: () -> Void) async {
        await withCheckedContinuation { continuation in
            finish = continuation
            begin()
        }
    }

    private func finished() {
        let continuation = finish
        finish = nil
        continuation?.resume()
    }

    /// Stops whatever is being said now. Neither player reports a stop it
    /// was told to make, so the wait is released here.
    private func cutCurrent() {
        player?.stop()
        player = nil
        utterance = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        finished()
    }

    private static func fallbackAcknowledgement(_ language: AppLanguage) -> String {
        switch language {
        case .english: "Okay, one moment."
        case .mandarin: "好的，稍等。"
        case .hindi: "ठीक है, एक पल।"
        case .spanish: "Vale, un momento."
        case .french: "D'accord, un instant."
        case .arabic: "حسنًا، لحظة."
        case .bengali: "ঠিক আছে, এক মুহূর্ত।"
        case .portuguese: "Certo, um momento."
        case .russian: "Хорошо, секунду."
        case .urdu: "ٹھیک ہے، ایک لمحہ۔"
        case .german: "Okay, einen Moment."
        case .italian: "Ok, un attimo."
        case .ukrainian: "Окей, зараз гляну."
        case .serbian: "Važi, samo tren."
        }
    }

    /// The best installed voice for `language`, or nil when there is none.
    /// Nil rather than the system default: an English voice reading Ukrainian
    /// is noise, and silence at least says something is missing.
    static func voice(for language: AppLanguage) -> AVSpeechSynthesisVoice? {
        let code = language.rawValue.lowercased()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(code) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
    }
}

/// Both players report the end of a line through a delegate, off the main
/// actor. One small object takes those calls so `SpokenAnswer` itself can
/// stay main-actor-only.
private final class FinishBridge: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    enum Source {
        case player(AVAudioPlayer)
        case utterance(AVSpeechUtterance)
    }

    private let onFinish: (Source) -> Void

    init(onFinish: @escaping (Source) -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        onFinish(.player(player))
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error _: Error?) {
        onFinish(.player(player))
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish(.utterance(utterance))
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onFinish(.utterance(utterance))
    }
}

/// An answer as it should be said rather than as it is drawn: markdown marks
/// are for the eye, and a voice reading "asterisk asterisk" is worse than none.
enum SpokenText {
    static func plain(_ markdown: String) -> String {
        var text = markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .map { tableRow(String($0)) }
            .joined(separator: "\n")
        for (regex, template) in rules {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A table line, read as its cells: the separator row is dropped, the
    /// edge pipes go, and the inner ones become pauses. Only lines that open
    /// with a pipe are tables — a pipe in prose or in a shell command stays.
    private static func tableRow(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return line }
        let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .dropFirst()
            .dropLast(trimmed.hasSuffix("|") ? 1 : 0)
        let isSeparator = cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
        return isSeparator ? "" : cells.joined(separator: ", ")
    }

    private static let rules: [(NSRegularExpression, String)] = [
        (#"```[\s\S]*?```"#, " "),
        (#"!\[[^\]]*\]\([^)]*\)"#, ""),
        (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
        (#"`([^`]*)`"#, "$1"),
        (#"(?m)^[ \t]{0,3}#{1,6}[ \t]+"#, ""),
        (#"(?m)^[ \t]*(?:[-*+]|\d{1,2}[.)])[ \t]+"#, ""),
        (#"(?m)^[ \t]*>[ \t]?"#, ""),
        (#"(?m)^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$"#, ""),
        (#"(?<!\w)\*\*(?!\s)(.+?)(?<!\s)\*\*(?!\w)"#, "$1"),
        // Double underscores are bold only around a phrase; around one word
        // they are a dunder, and `__init__` has to survive with its name.
        (#"(?<!\w)__(?!\s)(\S+\s.*?)(?<!\s)__(?!\w)"#, "$1"),
        (#"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, "$1"),
        (#"(?<!\w)_(?![\s_])(.+?)(?<![\s_])_(?!\w)"#, "$1"),
        (#"[ \t]+"#, " "),
        (#"\n{3,}"#, "\n\n")
    ].compactMap { pattern, template in
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return (regex, template)
    }
}
