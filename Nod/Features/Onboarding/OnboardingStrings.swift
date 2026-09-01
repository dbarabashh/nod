import Foundation

/// English-only copy for the onboarding flow. The app chrome is intentionally
/// not localized — only generated output (recaps, titles, cards, answers)
/// responds to the user's language pick. Transcription does not: Whisper runs
/// unconstrained and returns whatever was actually spoken. Same approach
/// Otter / Granola / Cleary take.
struct OnboardingStrings {
    let welcomeTitle: String
    let welcomeTagline: String
    let welcomeBullets: [WelcomeBullet]
    let welcomeLanguageLabel: String
    /// Sits under the language row. The pick is the first thing onboarding asks
    /// for, before the user has seen a single recap, so this is where the mental
    /// model gets set — or, until now, guessed at.
    let welcomeLanguageHint: String
    let welcomeContinue: String

    struct WelcomeBullet {
        let icon: String
        let text: String
    }

    let permissionsTitle: String
    let permissionsSubtitle: String

    let micTitle: String
    let micDescription: String

    let screenTitle: String
    let screenDescription: String

    let screenPreemptiveBody: String

    let actionEnable: String
    let actionOpenSettings: String
    let actionRelaunch: String
    let actionRelaunchHint: String
    let actionSkip: String
    let actionContinue: String
    let actionContinueAnyway: String
    let statusGranted: String
}

extension OnboardingStrings {
    static let english = OnboardingStrings(
        welcomeTitle: "Welcome to Nod",
        welcomeTagline: "Everything you talk through is kept, and handed back when you need it.",
        welcomeBullets: [
            .init(icon: "nc-video", text: "Meetings, voice notes, anything playing — captured off this Mac, with no bot joining."),
            .init(icon: "nc-sparkle-3", text: "Ask what was decided, what's still open, and what you committed to."),
            .init(icon: "nc-lock", text: "Audio leaves your Mac only during transcription — never stored.")
        ],
        welcomeLanguageLabel: "Nod language",
        welcomeLanguageHint: MeetingLanguagePrompt.scopeNote,
        welcomeContinue: "Continue",

        permissionsTitle: "Grant Permissions",
        permissionsSubtitle: "Nod captures through your Mac, so it needs the microphone and the system audio.",

        micTitle: "Microphone",
        micDescription: "Captures your own side — a call, or a voice note with nobody else in it.",

        screenTitle: "Screen Recording",
        screenDescription: "Required to capture system audio — the other side of a call, or anything playing.",

        screenPreemptiveBody: "Screen Recording is what macOS calls the permission to hear your Mac's own audio — the other side of a call. Nod doesn't record or transmit your screen; only the audio mix from your speakers.",

        actionEnable: "Enable",
        actionOpenSettings: "Open Settings",
        actionRelaunch: "Quit & Relaunch Nod",
        actionRelaunchHint: "Allowed Screen Recording? macOS only hands it to Nod after a restart — relaunch to finish capturing system audio.",
        actionSkip: "Skip for now",
        actionContinue: "Continue",
        actionContinueAnyway: "Continue Anyway",
        statusGranted: "Granted"
    )
}
