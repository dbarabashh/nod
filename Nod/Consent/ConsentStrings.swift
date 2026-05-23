import Foundation

/// English + Ukrainian copy for the pre-first-meeting consent disclaimer.
/// Pattern matches `OnboardingStrings` — selected by `LanguagePreference`.
struct ConsentStrings {
    let title: String
    let body: String
    let dontShowAgain: String
    let cancel: String
    let acknowledge: String

    static func forLanguageCode(_ code: String) -> ConsentStrings {
        switch code {
        case "uk":
            return ukrainian
        default:
            return english
        }
    }
}

extension ConsentStrings {
    static let english = ConsentStrings(
        title: "Before you record",
        body: "You are responsible for obtaining consent from meeting participants. Recording laws differ by jurisdiction — make sure everyone on the call knows Nod is listening.",
        dontShowAgain: "Don't show again",
        cancel: "Cancel",
        acknowledge: "Acknowledge & Start"
    )

    static let ukrainian = ConsentStrings(
        title: "Перед записом",
        body: "Ти відповідаєш за згоду учасників на запис. Закони щодо запису розмов різняться залежно від країни — переконайся, що всі учасники знають, що Nod слухає.",
        dontShowAgain: "Не показувати знову",
        cancel: "Скасувати",
        acknowledge: "Підтвердити й почати"
    )
}
