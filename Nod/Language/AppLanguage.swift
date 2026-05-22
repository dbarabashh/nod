import Foundation
import Combine

enum AppLanguage: String, CaseIterable {
    case english = "en"
    case ukrainian = "uk"

    /// Short two-letter label for the toggle chip.
    var chipLabel: String {
        switch self {
        case .english: return "EN"
        case .ukrainian: return "УК"
        }
    }

    /// Human-readable name passed to the LLM in the "Respond in X" instruction.
    var promptName: String {
        switch self {
        case .english: return "English"
        case .ukrainian: return "Ukrainian"
        }
    }

    /// BCP-47 / Whisper ISO-639-1 code.
    var whisperCode: String { rawValue }

    var next: AppLanguage {
        switch self {
        case .english: return .ukrainian
        case .ukrainian: return .english
        }
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
            self.current = .english
        }
    }

    func toggle() {
        current = current.next
    }

    /// Thread-safe snapshot of the current Whisper language code. Safe to call
    /// from audio threads.
    nonisolated func currentWhisperCode() -> String {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? AppLanguage.english.rawValue
        return AppLanguage(rawValue: raw)?.whisperCode ?? "en"
    }
}
