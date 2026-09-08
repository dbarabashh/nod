import AVFoundation
import CryptoKit
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
        /// An acknowledgement the client already holds the audio for.
        case aside(SpokenLine)
        case answer(String, question: String)

        var isAnswer: Bool {
            if case .answer = self { return true }
            return false
        }

        var purpose: String {
            switch self {
            case .acknowledgement, .aside: "acknowledgement"
            case .answer: "answer"
            }
        }

        var text: String {
            switch self {
            case let .acknowledgement(question): question
            case let .aside(clip): clip.transcript
            case let .answer(answer, _): answer
            }
        }

        var question: String {
            switch self {
            case let .acknowledgement(question), let .answer(_, question): question
            case .aside: ""
            }
        }
    }

    /// The proxy's cap on a line; an answer is cut to fit rather than refused.
    private static let maxLineLength = 1500

    /// The words being said right now, or nil once nothing is. Drives the
    /// notch's "Speaking" state.
    var onSpeaking: ((String?) -> Void)?

    private let llmClient: LLMProxyClient
    private let asides: SpokenAsides
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    /// One line fetched ahead of its moment, so a hello whose words are known
    /// before the person speaks starts the instant it is called for.
    private var prepared: (text: String, language: AppLanguage, fetch: Task<SpokenLine?, Never>)?
    private var queue: [(Line, AppLanguage)] = []
    private var playing: Line?
    private var finish: CheckedContinuation<Void, Never>?
    /// Bumped by `stop()`, so a line still being fetched when the person
    /// moved on is dropped rather than said late.
    private var generation = 0

    init(llmClient: LLMProxyClient) {
        self.llmClient = llmClient
        asides = SpokenAsides(llmClient: llmClient)
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

    /// Whether a line is on its way out — queued, being fetched, or playing.
    var isSaying: Bool {
        playing != nil || !queue.isEmpty
    }

    /// Said as soon as the question is understood, while the answer is still
    /// being worked out. A line kept ready plays at once; without one the
    /// proxy writes and says one for this question — five seconds the person
    /// spends in silence — and the next hold finds the ready line in place.
    func acknowledge(_ question: String, language: AppLanguage) {
        if let clip = asides.clip(for: language) {
            enqueue(.aside(clip), language: language)
        } else {
            enqueue(.acknowledgement(question: question), language: language)
            asides.prepare(language)
        }
    }

    /// Fetches the ready acknowledgement for `language` if there is none yet,
    /// so the first hold of the key is answered as fast as the tenth.
    func prepareAside(language: AppLanguage) {
        asides.prepare(language)
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

    /// Fetches the audio for an answer now, to be played when `say` is
    /// called with the same words. Anything else said meanwhile is unaffected.
    func prepare(_ answer: String, asking question: String, language: AppLanguage) {
        let text = String(answer.prefix(Self.maxLineLength))
        if let prepared, prepared.text == text, prepared.language == language { return }
        prepared?.fetch.cancel()
        let fetch = Task { [llmClient] in
            try? await llmClient.speak(text: text, question: question, language: language.rawValue, purpose: "answer")
        }
        prepared = (text, language, fetch)
    }

    /// The prepared clip for `line`, waited for if it is still on its way.
    private func preparedClip(for line: Line, language: AppLanguage) async -> SpokenLine? {
        guard let prepared, line.isAnswer, prepared.text == line.text, prepared.language == language else { return nil }
        self.prepared = nil
        return await prepared.fetch.value
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
    ///
    /// A line whose audio is in hand plays as one clip. An answer is fetched
    /// a clip at a time and each plays as it arrives, so the voice starts on
    /// the first sentence while the proxy is still making the rest.
    private func voice(_ line: Line, language: AppLanguage, generation: Int) async {
        var played = 0
        do {
            if case let .aside(clip) = line {
                try await play(clip, purpose: line.purpose, language: language, generation: generation)
                return
            }
            if let clip = await preparedClip(for: line, language: language) {
                try await play(clip, purpose: line.purpose, language: language, generation: generation)
                return
            }
            var transcript = line.text
            for try await event in llmClient.speakInClips(
                text: line.text,
                question: line.question,
                language: language.rawValue,
                purpose: line.purpose
            ) {
                guard generation == self.generation else { return }
                switch event {
                case let .transcript(words):
                    transcript = words
                case let .clip(audio):
                    try await play(
                        SpokenLine(audio: audio, transcript: transcript),
                        purpose: line.purpose,
                        language: language,
                        generation: generation,
                        announce: played == 0
                    )
                    played += 1
                    // A cut lands while a clip plays; leaving the loop here
                    // drops the stream at once instead of after its next clip.
                    guard generation == self.generation else { return }
                case .missing:
                    Log.ui.error("spoken: a clip of the \(line.purpose) was not made")
                }
            }
            guard generation == self.generation, played == 0 else { return }
            Log.ui.error("spoken: no clip of the \(line.purpose) arrived — using the system voice")
            await speakOnDevice(line, language: language)
        } catch {
            guard generation == self.generation else { return }
            guard played == 0 else {
                Log.ui.error("spoken: the \(line.purpose) broke off after \(played) clip(s) — \(error.localizedDescription)")
                return
            }
            Log.ui.error("spoken: proxy voice failed (\(error.localizedDescription)) — using the system voice")
            await speakOnDevice(line, language: language)
        }
    }

    /// Plays one clip through to its end, or to the cut.
    private func play(_ clip: SpokenLine, purpose: String, language: AppLanguage, generation: Int, announce: Bool = true) async throws {
        let player = try AVAudioPlayer(data: clip.audio)
        player.delegate = delegateBridge
        self.player = player
        if announce {
            onSpeaking?(clip.transcript)
            Log.ui.info("spoken: \(purpose) in \(language.rawValue), \(clip.transcript.count) chars via proxy voice")
        }
        var started = false
        await untilFinished {
            started = player.play()
            if !started { finished() }
        }
        self.player = nil
        guard !started, generation == self.generation else { return }
        throw PlaybackFailure.playerRefused
    }

    private enum PlaybackFailure: Error {
        case playerRefused
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

    // A switch rather than a table, so adding a language to `AppLanguage` fails
    // to compile until somebody writes what Nod says in it. The complexity
    // metric counts thirty-five one-line cases as branching; it isn't.
    // swiftlint:disable:next cyclomatic_complexity
    static func fallbackAcknowledgement(_ language: AppLanguage) -> String {
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
        case .japanese: "はい、少々お待ちください。"
        case .marathi: "ठीक आहे, एक क्षण."
        case .turkish: "Tamam, bir saniye."
        case .cantonese: "好，等一陣。"
        case .vietnamese: "Được, chờ một chút."
        case .korean: "네, 잠시만요."
        case .persian: "باشه، یک لحظه."
        case .italian: "Ok, un attimo."
        case .polish: "Dobrze, chwileczkę."
        case .ukrainian: "Окей, зараз гляну."
        case .zulu: "Kulungile, umzuzwana."
        case .dutch: "Oké, een moment."
        case .romanian: "Bine, o clipă."
        case .afrikaans: "Goed, een oomblik."
        case .xhosa: "Kulungile, umzuzwana."
        case .swedish: "Okej, ett ögonblick."
        case .serbian: "Važi, samo tren."
        case .hebrew: "בסדר, רגע אחד."
        case .catalan: "D'acord, un moment."
        case .danish: "Okay, et øjeblik."
        case .finnish: "Selvä, hetki."
        case .norwegian: "Ok, et øyeblikk."
        case .galician: "Vale, un momento."
        case .estonian: "Selge, üks hetk."
        }
    }

    /// The best installed voice for `language`, or nil when there is none.
    /// Nil rather than the system default: an English voice reading Ukrainian
    /// is noise, and silence at least says something is missing.
    static func voice(for language: AppLanguage) -> AVSpeechSynthesisVoice? {
        // Not the raw value: `AVSpeechSynthesisVoice` files Cantonese under the
        // Chinese macrolanguage with a Hong Kong region, so matching on "yue"
        // finds nothing and the one language with a shipped voice reads as the
        // one without.
        let code = language == .cantonese ? "zh-hk" : language.rawValue.lowercased()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(code) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
    }
}

/// The acknowledgements kept ready, one per language: the line every
/// language already has for the on-device fallback, said once by the proxy's
/// voice and kept on disk. Writing an aside for each question and saying it
/// cost five seconds between the question and the first sound — the whole
/// point of an aside is that it comes at once.
@MainActor
final class SpokenAsides {
    private let llmClient: LLMProxyClient
    private var clips: [AppLanguage: SpokenLine] = [:]
    private var pending: Set<AppLanguage> = []

    init(llmClient: LLMProxyClient) {
        self.llmClient = llmClient
    }

    func clip(for language: AppLanguage) -> SpokenLine? {
        if let clip = clips[language] { return clip }
        let line = SpokenAnswer.fallbackAcknowledgement(language)
        guard let audio = try? Data(contentsOf: Self.file(for: language, line: line)), !audio.isEmpty else { return nil }
        let clip = SpokenLine(audio: audio, transcript: line)
        clips[language] = clip
        return clip
    }

    func prepare(_ language: AppLanguage) {
        guard clip(for: language) == nil, !pending.contains(language) else { return }
        pending.insert(language)
        Task { [weak self] in
            defer { self?.pending.remove(language) }
            guard let self else { return }
            let line = SpokenAnswer.fallbackAcknowledgement(language)
            guard let clip = try? await llmClient.speak(
                text: line, question: "", language: language.rawValue, purpose: "acknowledgement", verbatim: true
            ) else { return }
            clips[language] = clip
            try? clip.audio.write(to: Self.file(for: language, line: line))
        }
    }

    /// Named by the words as well as the language, so a reworded line misses
    /// the cache instead of playing the old audio under the new transcript.
    private static func file(for language: AppLanguage, line: String) -> URL {
        let digest = SHA256.hash(data: Data(line.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return AppSupport.directory("spoken-asides").appendingPathComponent("\(language.rawValue)-\(digest).mp3")
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
