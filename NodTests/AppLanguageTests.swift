import XCTest
@testable import Nod

final class AppLanguageTests: XCTestCase {
    func testRawValueRoundTrips() {
        for lang in AppLanguage.allCases {
            XCTAssertEqual(AppLanguage(rawValue: lang.rawValue), lang)
        }
    }

    func testChipLabelIsUppercasedCode() {
        XCTAssertEqual(AppLanguage.spanish.chipLabel, "ES")
    }

    func testUnknownCodeIsNil() {
        XCTAssertNil(AppLanguage(rawValue: "xx"))
    }

    func testEveryCodeIsWhatLocaleNormalizesItTo() {
        // `detectFromSystemLocale` and `detect(from:)` both look a raw value up
        // after passing the system's tag through `Locale`, so a code that is not
        // already in that normalized form is a language the app offers and can
        // never detect. Cantonese is the one three-letter entry, because ISO
        // 639-1 has no code for it.
        for lang in AppLanguage.allCases {
            XCTAssertEqual(
                Locale(identifier: lang.rawValue).language.languageCode?.identifier,
                lang.rawValue,
                lang.promptName
            )
        }
    }

    func testNothingIsEverDropped() {
        // A code that stops being offered is still sitting in some user's
        // `app.language`, and a raw value that no longer decodes silently
        // resets their Nod to English. This list only ever grows.
        let shipped = [
            "en", "zh", "hi", "es", "fr", "ar", "bn", "pt", "ru", "ur", "de", "ja",
            "mr", "tr", "yue", "vi", "ko", "fa", "it", "pl", "uk", "zu", "nl", "ro",
            "af", "xh", "sv", "sr", "he", "ca", "da", "fi", "nb", "gl", "et"
        ]
        for code in shipped {
            XCTAssertNotNil(AppLanguage(rawValue: code), code)
        }
    }

    func testEveryLanguageIsNamedInBothDirections() {
        for lang in AppLanguage.allCases {
            XCTAssertFalse(lang.nativeName.isEmpty, lang.rawValue)
            XCTAssertFalse(lang.promptName.isEmpty, lang.rawValue)
        }
        XCTAssertEqual(Set(AppLanguage.allCases.map(\.nativeName)).count, AppLanguage.allCases.count)
        XCTAssertEqual(Set(AppLanguage.allCases.map(\.promptName)).count, AppLanguage.allCases.count)
    }
}

@MainActor
final class LanguagePreferenceTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.removeObject(forKey: LanguagePreference.key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: LanguagePreference.key)
    }

    func testPreferenceReadsPersistedValue() {
        UserDefaults.standard.set("uk", forKey: LanguagePreference.key)
        let pref = LanguagePreference()
        XCTAssertEqual(pref.current, .ukrainian)
    }

    func testPreferencePersistsLiveChange() {
        let pref = LanguagePreference()
        pref.current = .french
        XCTAssertEqual(UserDefaults.standard.string(forKey: LanguagePreference.key), "fr")
    }

    func testPreferenceFallsBackToSystemSupportedLanguageOnGarbage() {
        UserDefaults.standard.set("not-a-language", forKey: LanguagePreference.key)
        let pref = LanguagePreference()
        XCTAssertTrue(AppLanguage.allCases.contains(pref.current))
    }

    // MARK: - How the menu is grouped

    func testEveryLanguageIsInExactlyOneRegion() {
        let grouped = AppLanguage.byRegion().flatMap(\.languages)
        XCTAssertEqual(Set(grouped), Set(AppLanguage.allCases))
        XCTAssertEqual(grouped.count, AppLanguage.allCases.count)
    }

    func testNoRegionIsEmptyAndNoneIsLongEnoughToScroll() {
        // The whole point of the split: thirty-five in one menu reaches the
        // bottom of the screen. A region that grew past a normal menu's length
        // would put it back.
        for group in AppLanguage.byRegion() {
            XCTAssertFalse(group.languages.isEmpty, group.region.title)
            XCTAssertLessThanOrEqual(group.languages.count, 16, group.region.title)
        }
    }

    func testARegionKeepsTheSpeakerCountOrder() {
        let europe = AppLanguage.byRegion().first { $0.region == .europe }?.languages
        XCTAssertEqual(europe?.first, .english)
        XCTAssertEqual(
            europe,
            AppLanguage.allCases.filter { $0.region == .europe }
        )
    }

    func testTheSystemShortlistIsBoundedAndSupported() {
        let preferred = AppLanguage.systemPreferred()
        XCTAssertLessThanOrEqual(preferred.count, 3)
        XCTAssertEqual(Set(preferred).count, preferred.count)
        for language in preferred {
            XCTAssertTrue(AppLanguage.allCases.contains(language))
        }
    }
}
