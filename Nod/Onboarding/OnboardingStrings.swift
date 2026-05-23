import Foundation

/// English + Ukrainian copy for onboarding. Switched off `LanguagePreference`.
/// Localizing only this surface for now — issue #3 ACs require en/uk; broader
/// localization is tracked under #12.
struct OnboardingStrings {
    let welcomeTitle: String
    let welcomeTagline: String
    let welcomeBullets: [WelcomeBullet]
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

    static func forLanguageCode(_ code: String) -> OnboardingStrings {
        switch code {
        case "uk":
            return ukrainian
        default:
            return english
        }
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
        actionRelaunchHint: "Screen Recording is granted. Relaunch Nod so it can capture system audio.",
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
        tutorialPrivacy: "Mic, language, and sign-out live in the floating panel — change them any time.",
        tutorialGotIt: "Got it"
    )

    static let ukrainian = OnboardingStrings(
        welcomeTitle: "Вітаємо в Nod",
        welcomeTagline: "Ваш помічник на зустрічах — слухає під час дзвінка, підсумовує після завершення.",
        welcomeBullets: [
            .init(icon: "waveform", text: "Записує і вас, і ваших співрозмовників."),
            .init(icon: "sparkles", text: "Запитуйте ключові тези, питання чи проміжний підсумок прямо під час дзвінка."),
            .init(icon: "lock.fill", text: "Аудіо залишає ваш Mac лише на час транскрипції — нічого не зберігається.")
        ],
        welcomeContinue: "Далі",

        permissionsTitle: "Надайте дозволи",
        permissionsSubtitle: "Nod потрібен доступ до мікрофона та системного звуку, щоб записувати зустрічі.",

        micTitle: "Мікрофон",
        micDescription: "Записує те, що ви говорите під час зустрічі.",

        screenTitle: "Запис екрана",
        screenDescription: "Потрібен для запису системного звуку з застосунку для зустрічей.",

        screenPreemptiveTitle: "Навіщо «Запис екрана»?",
        screenPreemptiveBody: "Цей дозвіл потрібен лише для запису системного звуку — голосу інших учасників. Nod не записує і не передає зображення екрана; лише звуковий мікс із ваших динаміків.",

        guideStep1Title: "Відкрийте «Приватність і безпека»",
        guideStep1Detail: "У «Системних налаштуваннях» прокрутіть до «Приватність і безпека».",
        guideStep2Title: "Увімкніть Nod у «Запис екрана»",
        guideStep2Detail: "Перемкніть Nod у позицію «увімкнено». macOS попросить перезапустити застосунок.",

        actionEnable: "Увімкнути",
        actionOpenSettings: "Відкрити налаштування",
        actionRelaunch: "Перезапустити Nod",
        actionRelaunchHint: "Дозвіл надано. Перезапустіть Nod, щоб він міг записувати системний звук.",
        actionSkip: "Пропустити",
        actionContinue: "Продовжити",
        actionContinueAnyway: "Продовжити все одно",
        actionFinish: "Далі",
        statusGranted: "Надано",

        tutorialTitle: "Ваша перша зустріч",
        tutorialBullets: [
            .init(
                icon: "record.circle",
                title: "Натисніть «Start Meeting» на плаваючій панелі",
                body: "Панель розташована ліворуч на екрані. Над кнопкою показано найближчу подію з вашого календаря."
            ),
            .init(
                icon: "sparkles",
                title: "Запитуйте Nod під час дзвінка",
                body: "Натисніть «Catch me up», «Key points», «Suggest follow-up questions» чи «Recap so far», коли потрібна допомога."
            ),
            .init(
                icon: "doc.text",
                title: "Отримайте підсумок після завершення",
                body: "Натисніть «End» — і Nod згенерує підсумок зустрічі, який можна скопіювати. Жодних записів не зберігається — аудіо залишає Mac лише для транскрипції."
            )
        ],
        tutorialPrivacy: "Мікрофон, мову й вихід з акаунту можна змінити будь-коли з плаваючої панелі.",
        tutorialGotIt: "Зрозуміло"
    )
}
