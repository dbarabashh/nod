import Foundation

/// English-only copy for the onboarding flow. The app chrome is intentionally
/// not localized — only the transcription and LLM output respond to the user's
/// language pick. Same approach Otter / Granola / Cleary take.
struct OnboardingStrings {
    let welcomeTitle: String
    let welcomeTagline: String
    let welcomeBullets: [WelcomeBullet]
    let welcomeLanguageLabel: String
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

    let screenPreemptiveTitle: String
    let screenPreemptiveBody: String

    let guideStep1Title: String
    let guideStep1Detail: String
    let guideStep2Title: String
    let guideStep2Detail: String

    let actionEnable: String
    let actionOpenSettings: String
    let actionRelaunch: String
    let actionRelaunchHint: String
    let actionSkip: String
    let actionContinue: String
    let actionContinueAnyway: String
    let actionFinish: String
    let statusGranted: String

    let tutorialTitle: String
    let tutorialBullets: [TutorialBullet]
    let tutorialPrivacy: String
    let tutorialGotIt: String

    struct TutorialBullet {
        let icon: String
        let title: String
        let body: String
    }
}

extension OnboardingStrings {
    static let english = OnboardingStrings(
        welcomeTitle: "Welcome to Nod",
        welcomeTagline: "Your meeting copilot — listens during the call, recaps when you're done.",
        welcomeBullets: [
            .init(icon: "waveform", text: "Captures both you and the other side of the call."),
            .init(icon: "sparkles", text: "Ask for key points, follow-ups, or a recap mid-meeting."),
            .init(icon: "lock.fill", text: "Audio leaves your Mac only during transcription — never stored.")
        ],
        welcomeLanguageLabel: "Nod language",
        welcomeContinue: "Continue",

        permissionsTitle: "Grant Permissions",
        permissionsSubtitle: "Nod needs access to your microphone and system audio to record meetings.",

        micTitle: "Microphone",
        micDescription: "Captures what you say during the meeting.",

        screenTitle: "Screen Recording",
        screenDescription: "Required to capture system audio from your meeting app.",

        screenPreemptiveTitle: "Why Screen Recording?",
        screenPreemptiveBody: "Screen Recording is required to capture system audio — the other people in your meeting. Nod doesn't record or transmit your screen; only the audio mix from your speakers.",

        guideStep1Title: "Open Privacy & Security",
        guideStep1Detail: "In System Settings, scroll to Privacy & Security.",
        guideStep2Title: "Enable Nod under Screen Recording",
        guideStep2Detail: "Toggle Nod on. macOS will ask you to quit and reopen.",

        actionEnable: "Enable",
        actionOpenSettings: "Open Settings",
        actionRelaunch: "Quit & Relaunch Nod",
        actionRelaunchHint: "Allowed Screen Recording? macOS only hands it to Nod after a restart — relaunch to finish capturing system audio.",
        actionSkip: "Skip for now",
        actionContinue: "Continue",
        actionContinueAnyway: "Continue Anyway",
        actionFinish: "Continue",
        statusGranted: "Granted",

        tutorialTitle: "Your first meeting",
        tutorialBullets: [
            .init(
                icon: "record.circle",
                title: "Hit Start Meeting on the floating panel",
                body: "The panel sits on the left of your screen. The next upcoming event from your calendar shows above the button."
            ),
            .init(
                icon: "sparkles",
                title: "Ask Nod during the call",
                body: "Tap Catch me up, Key points, Suggest follow-up questions, or Recap so far whenever you need a hand."
            ),
            .init(
                icon: "doc.text",
                title: "Get a recap when you end",
                body: "Hit End and Nod generates a meeting summary you can copy. Nothing is recorded or kept — audio only leaves your Mac for transcription."
            )
        ],
        tutorialPrivacy: "Mic, Nod language, and sign-out live in the floating panel — change them any time.",
        tutorialGotIt: "Got it"
    )
}
