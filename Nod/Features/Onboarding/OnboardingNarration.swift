import Foundation

/// The scripted voiceover said once, on arrival, at each step of onboarding —
/// the window's two steps and the notch's setup cards alike. English-only,
/// matching `OnboardingStrings`: app chrome is not localized, only generated
/// output is.
enum OnboardingNarration {
    /// The very first thing Nod says. Matches `WelcomeStep.greeting`'s own
    /// name-or-not logic — same name, same fallback — since the two are read
    /// and heard in the same breath.
    static func welcome(firstName: String?) -> String {
        let greeting = firstName.map { "Hi, \($0)." } ?? "Hi there."
        return "\(greeting) I'm Nod — I sit in on your meetings, keep an eye on your day, and remember it " +
            "all, so you can just ask instead of digging back through notes. Pick your language below, then " +
            "hit Give me a home and let's get you set up."
    }

    static let profile =
        "One more thing before we go — tell me a bit about yourself, so the way I talk to you actually fits " +
        "how you work. There's also a spot for how you heard about us — that one genuinely helps, it tells " +
        "our small team where to spend our time next. Fill in what you'd like, then hit continue."

    static func setupStage(_ stage: NotchSetupStage) -> String? {
        switch stage {
        case .intro:
            "This is where I live from now on — up here, out of your way until you need me."
        case .microphone:
            "First, your microphone — that's how I hear your side of a conversation."
        case .systemAudio:
            "And this lets me hear the other side too, whatever's playing through your speakers."
        case .ambient:
            "This one's optional — a quick glance at your screen every so often, so I know what you're " +
                "working on, not just what you say out loud."
        case .calendar:
            "Connect your calendar and I'll know what's coming up, and offer to record the moment a meeting " +
                "starts."
        case .ready:
            "That's everything. Let's try it out."
        case .firstAsk:
            nil // The first question is the point of this card; it speaks for itself.
        }
    }
}
