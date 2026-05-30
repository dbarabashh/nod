import Foundation
import Combine

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
    var chipLabel: String { rawValue.uppercased() }

    /// Endonym — what speakers of this language call it. Used in the picker
    /// so a Spanish speaker sees "Español", not "Spanish".
    var nativeName: String {
        switch self {
        case .english: return "English"
        case .mandarin: return "中文"
        case .hindi: return "हिन्दी"
        case .spanish: return "Español"
        case .french: return "Français"
        case .arabic: return "العربية"
        case .bengali: return "বাংলা"
        case .portuguese: return "Português"
        case .russian: return "Русский"
        case .urdu: return "اردو"
        case .ukrainian: return "Українська"
        case .serbian: return "Српски"
        }
    }

    /// English name passed to the LLM in the "Respond in X" instruction.
    /// Models reliably understand English language names even when generating
    /// in another language.
    var promptName: String {
        switch self {
        case .english: return "English"
        case .mandarin: return "Mandarin Chinese"
        case .hindi: return "Hindi"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .arabic: return "Arabic"
        case .bengali: return "Bengali"
        case .portuguese: return "Portuguese"
        case .russian: return "Russian"
        case .urdu: return "Urdu"
        case .ukrainian: return "Ukrainian"
        case .serbian: return "Serbian"
        }
    }

    /// BCP-47 / Whisper ISO-639-1 code.
    var whisperCode: String { rawValue }

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
            self.current = lang
        } else {
            // didSet does not fire during init, so persist the detected
            // default here — otherwise `currentWhisperCode()` (which reads
            // UserDefaults directly from the audio thread) falls back to
            // "en" and Whisper transcribes in the wrong language until the
            // user manually re-selects.
            let detected = AppLanguage.detectFromSystemLocale()
            UserDefaults.standard.set(detected.rawValue, forKey: Self.key)
            self.current = detected
        }
    }

    /// Thread-safe snapshot of the current Whisper language code. Safe to call
    /// from audio threads.
    nonisolated func currentWhisperCode() -> String {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? AppLanguage.english.rawValue
        return AppLanguage(rawValue: raw)?.whisperCode ?? "en"
    }
}
