import Combine
import Foundation
import NaturalLanguage

/// The set of languages Nod accepts as transcription input + LLM output.
/// The app UI (onboarding, consent, buttons) is intentionally English-only —
/// translating the chrome for every supported language is a maintenance
/// burden Otter/Granola/Cleary also don't pay. Only transcription and LLM
/// output respond to the user's pick.
enum AppLanguage: String, CaseIterable {
    // Ordered by global speaker count (Ethnologue 2024) so the picker presents
    // the most common choices first. Ukrainian is kept off the top-10 list as
    // the founder's home market — it's the differentiator, not a fluke.
    case english = "en"
    case mandarin = "zh"
    case hindi = "hi"
    case spanish = "es"
    case french = "fr"
    case arabic = "ar"
    case bengali = "bn"
    case portuguese = "pt"
    case russian = "ru"
    case urdu = "ur"
    case ukrainian = "uk"
    case serbian = "sr"

    /// Two-letter code shown on the floating-panel chip. Just the ISO code
    /// uppercased — a localized chip would mean N different glyph widths.
    var chipLabel: String {
        rawValue.uppercased()
    }

    /// Endonym — what speakers of this language call it. Used in the picker
    /// so a Spanish speaker sees "Español", not "Spanish".
    var nativeName: String {
        switch self {
        case .english: "English"
        case .mandarin: "中文"
        case .hindi: "हिन्दी"
        case .spanish: "Español"
        case .french: "Français"
        case .arabic: "العربية"
        case .bengali: "বাংলা"
        case .portuguese: "Português"
        case .russian: "Русский"
        case .urdu: "اردو"
        case .ukrainian: "Українська"
        case .serbian: "Српски"
        }
    }

    /// English name passed to the LLM in the "Respond in X" instruction.
    /// Models reliably understand English language names even when generating
    /// in another language.
    var promptName: String {
        switch self {
        case .english: "English"
        case .mandarin: "Mandarin Chinese"
        case .hindi: "Hindi"
        case .spanish: "Spanish"
        case .french: "French"
        case .arabic: "Arabic"
        case .bengali: "Bengali"
        case .portuguese: "Portuguese"
        case .russian: "Russian"
        case .urdu: "Urdu"
        case .ukrainian: "Ukrainian"
        case .serbian: "Serbian"
        }
    }

    /// BCP-47 / Whisper ISO-639-1 code.
    var whisperCode: String {
        rawValue
    }

    /// Best supported match for the user's system locale, or English if none
    /// of the user's preferred languages are in our supported set. Used as the
    /// onboarding default so the picker arrives pre-filled.
    ///
    /// Parses via `Locale(identifier:).language.languageCode` so BCP-47 tags
    /// with script/region subtags (e.g. `zh-Hans-CN`, `pt-BR`) and 3-letter
    /// codes (e.g. `ukr`, `spa`) normalize correctly — a naive `prefix(2)`
    /// would mishandle 3-letter tags and silently miscategorize them.
    static func detectFromSystemLocale() -> AppLanguage {
        for tag in Locale.preferredLanguages {
            guard let code = Locale(identifier: tag).language.languageCode?.identifier.lowercased() else {
                continue
            }
            if let match = AppLanguage(rawValue: code) {
                return match
            }
        }
        return .english
    }

    /// Best-effort dominant language of a user message, mapped to a supported
    /// `AppLanguage`. Used so a chat answer matches the language the user typed
    /// in — deterministically, instead of hoping the model honours a soft
    /// prompt rule. Returns nil for text too short/ambiguous to call
    /// confidently; callers fall back to a sensible default.
    static func detect(from text: String) -> AppLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.6 else { return nil }
        // NLLanguage carries a script subtag for some languages (Chinese →
        // "zh-Hans"/"zh-Hant"); take the primary subtag so it maps to our
        // 2-letter codes ("zh"). Others ("en", "uk", …) pass through unchanged.
        let code = language.rawValue.split(separator: "-").first.map(String.init) ?? language.rawValue
        return AppLanguage(rawValue: code)
    }
}

/// Persisted in UserDefaults so the user's language choice survives a restart.
/// Read from any thread; writes hop to main.
@MainActor
final class LanguagePreference: ObservableObject {
    @Published var current: AppLanguage {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: Self.key)
            Log.ui.info("language → \(current.rawValue)")
        }
    }

    nonisolated static let key = "app.language"

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key),
           let lang = AppLanguage(rawValue: raw) {
            current = lang
        } else {
            // didSet does not fire during init, so persist the detected
            // default here — otherwise `currentWhisperCode()` (which reads
            // UserDefaults directly from the audio thread) falls back to
            // "en" and Whisper transcribes in the wrong language until the
            // user manually re-selects.
            let detected = AppLanguage.detectFromSystemLocale()
            UserDefaults.standard.set(detected.rawValue, forKey: Self.key)
            current = detected
        }
    }

    /// Thread-safe snapshot of the current Whisper language code. Safe to call
    /// from audio threads.
    nonisolated func currentWhisperCode() -> String {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? AppLanguage.english.rawValue
        return AppLanguage(rawValue: raw)?.whisperCode ?? "en"
    }
}
