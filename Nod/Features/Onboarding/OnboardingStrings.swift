import Foundation

/// English-only copy for the onboarding flow. The app chrome is intentionally
/// not localized — only generated output (recaps, titles, cards, answers)
/// responds to the user's language pick. Transcription does not: Whisper runs
/// unconstrained and returns whatever was actually spoken. Same approach
/// Otter / Granola / Cleary take.
struct OnboardingStrings {
    /// The greeting when the account has no name to greet by.
    let welcomeTitle: String
    let welcomeTagline: String
    let welcomeLanguageLabel: String
    /// Sits under the language row. The pick is the first thing onboarding asks
    /// for, before the user has seen a single recap, so this is where the mental
    /// model gets set — or, until now, guessed at.
    let welcomeLanguageHint: String
    let welcomeContinue: String
}

extension OnboardingStrings {
    static let english = OnboardingStrings(
        welcomeTitle: "Hi there.",
        welcomeTagline: "I'm Nod. I remember your meetings, your day and what's on your screen — so you can just ask.",
        welcomeLanguageLabel: "Nod language",
        welcomeLanguageHint: MeetingLanguagePrompt.scopeNote,
        welcomeContinue: "Give me a home"
    )
}
