import Foundation

/// English-only copy for the pre-first-meeting consent disclaimer.
/// The app chrome is intentionally not localized — see `OnboardingStrings`.
struct ConsentStrings {
    let title: String
    let body: String
    let dontShowAgain: String
    let cancel: String
    let acknowledge: String
}

extension ConsentStrings {
    static let english = ConsentStrings(
        title: "Before you record",
        body: "You are responsible for obtaining consent from meeting participants. Recording laws differ by jurisdiction — make sure everyone on the call knows Nod is listening.",
        dontShowAgain: "Don't show again",
        cancel: "Cancel",
        acknowledge: "Acknowledge & Start"
    )
}
