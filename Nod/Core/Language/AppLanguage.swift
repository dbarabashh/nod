import Combine
import Foundation
import NaturalLanguage

/// The set of languages Nod accepts for generated output.
/// The app UI (onboarding, consent, buttons) is intentionally English-only —
/// translating the chrome for every supported language is a maintenance
/// burden Otter/Granola/Cleary also don't pay. Transcription stays
/// auto/multilingual; this pick controls summaries, titles, cards, and answers.
enum AppLanguage: String, CaseIterable {
    // Ordered by global speaker count (Ethnologue 2024) so the picker presents
    // the most common choices first. Ukrainian is kept off the top of the list
    // as the founder's home market — it's the differentiator, not a fluke.
    //
    // Codes are the language subtag `Locale` normalizes to, which is what
    // `detectFromSystemLocale` and `detect(from:)` both match against. Two
    // letters everywhere ISO 639-1 has one; Cantonese has none, so it carries
    // its 639-3 code and is the only three-letter entry.
    //
    // Nothing is ever removed from this list. A code that stops being offered
    // is still sitting in some user's `app.language`, and a raw value that no
    // longer decodes silently resets their Nod to English.
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
    case german = "de"
    case japanese = "ja"
    case marathi = "mr"
    case turkish = "tr"
    case cantonese = "yue"
    case vietnamese = "vi"
    case korean = "ko"
    case persian = "fa"
    case italian = "it"
    case polish = "pl"
    case ukrainian = "uk"
    case zulu = "zu"
    case dutch = "nl"
    case romanian = "ro"
    case afrikaans = "af"
    case xhosa = "xh"
    case swedish = "sv"
    case serbian = "sr"
    case hebrew = "he"
    case catalan = "ca"
    case danish = "da"
    case finnish = "fi"
    case norwegian = "nb"
    case galician = "gl"
    case estonian = "et"

    /// The code shown on the floating-panel chip. Just the ISO code uppercased
    /// — a localized chip would mean N different glyph widths. Two letters for
    /// all but Cantonese, which has no two-letter code to shorten to.
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
        case .german: "Deutsch"
        case .japanese: "日本語"
        case .marathi: "मराठी"
        case .turkish: "Türkçe"
        case .cantonese: "廣東話"
        case .vietnamese: "Tiếng Việt"
        case .korean: "한국어"
        case .persian: "فارسی"
        case .italian: "Italiano"
        case .polish: "Polski"
        case .ukrainian: "Українська"
        case .zulu: "isiZulu"
        case .dutch: "Nederlands"
        case .romanian: "Română"
        case .afrikaans: "Afrikaans"
        case .xhosa: "isiXhosa"
        case .swedish: "Svenska"
        case .serbian: "Српски"
        case .hebrew: "עברית"
        case .catalan: "Català"
        case .danish: "Dansk"
        case .finnish: "Suomi"
        case .norwegian: "Norsk"
        case .galician: "Galego"
        case .estonian: "Eesti"
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
        case .german: "German"
        case .japanese: "Japanese"
        case .marathi: "Marathi"
        case .turkish: "Turkish"
        case .cantonese: "Cantonese"
        case .vietnamese: "Vietnamese"
        case .korean: "Korean"
        case .persian: "Persian"
        case .italian: "Italian"
        case .polish: "Polish"
        case .ukrainian: "Ukrainian"
        case .zulu: "Zulu"
        case .dutch: "Dutch"
        case .romanian: "Romanian"
        case .afrikaans: "Afrikaans"
        case .xhosa: "Xhosa"
        case .swedish: "Swedish"
        case .serbian: "Serbian"
        case .hebrew: "Hebrew"
        case .catalan: "Catalan"
        case .danish: "Danish"
        case .finnish: "Finnish"
        case .norwegian: "Norwegian"
        case .galician: "Galician"
        case .estonian: "Estonian"
        }
    }

    /// Where a language is looked for, so a menu of thirty-five can be a menu
    /// of six. Not linguistics — a person hunting for Polski scans "Europe",
    /// not "West Slavic", and Afrikaans is looked for where it is spoken rather
    /// than where its grammar came from.
    enum Region: String, CaseIterable {
        case europe
        case nordicAndBaltic
        case middleEast
        case southAsia
        case eastAsia
        case africa

        var title: String {
            switch self {
            case .europe: "Europe"
            case .nordicAndBaltic: "Nordic & Baltic"
            case .middleEast: "Middle East"
            case .southAsia: "South Asia"
            case .eastAsia: "East & Southeast Asia"
            case .africa: "Africa"
            }
        }
    }

    var region: Region {
        switch self {
        case .english, .spanish, .french, .german, .italian, .portuguese, .dutch,
             .polish, .ukrainian, .russian, .serbian, .romanian, .catalan, .galician:
            .europe
        case .swedish, .norwegian, .danish, .finnish, .estonian:
            .nordicAndBaltic
        case .arabic, .hebrew, .persian, .turkish:
            .middleEast
        case .hindi, .marathi, .bengali, .urdu:
            .southAsia
        case .mandarin, .cantonese, .japanese, .korean, .vietnamese:
            .eastAsia
        case .afrikaans, .zulu, .xhosa:
            .africa
        }
    }

    /// Every language under its region, regions in a fixed order and languages
    /// keeping the speaker-count order of `allCases` inside each.
    static func byRegion() -> [(region: Region, languages: [AppLanguage])] {
        Region.allCases.map { region in
            (region, allCases.filter { $0.region == region })
        }
    }

    /// The handful worth showing before the regions: what the user's own Mac
    /// asks for, in the order it asks. A menu that opens on the two languages
    /// somebody actually works in is a menu they never have to read.
    static func systemPreferred(limit: Int = 3) -> [AppLanguage] {
        var seen: [AppLanguage] = []
        for tag in Locale.preferredLanguages {
            guard let code = Locale(identifier: tag).language.languageCode?.identifier.lowercased(),
                  let match = AppLanguage(rawValue: code), !seen.contains(match)
            else { continue }
            seen.append(match)
            if seen.count == limit { break }
        }
        return seen
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

/// Persisted in UserDefaults so the user's Nod language survives a restart.
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
            let detected = AppLanguage.detectFromSystemLocale()
            UserDefaults.standard.set(detected.rawValue, forKey: Self.key)
            current = detected
        }
    }
}
