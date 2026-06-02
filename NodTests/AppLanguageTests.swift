import XCTest
@testable import Nod

final class AppLanguageTests: XCTestCase {
    func testWhisperCodeMatchesRawValue() {
        XCTAssertEqual(AppLanguage.english.whisperCode, "en")
        XCTAssertEqual(AppLanguage.ukrainian.whisperCode, "uk")
        XCTAssertEqual(AppLanguage.mandarin.whisperCode, "zh")
    }

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
}

@MainActor
final class LanguagePreferenceTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.removeObject(forKey: LanguagePreference.key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: LanguagePreference.key)
    }

    func testCurrentWhisperCodeReadsPersistedValue() {
        UserDefaults.standard.set("uk", forKey: LanguagePreference.key)
        let pref = LanguagePreference()
        XCTAssertEqual(pref.currentWhisperCode(), "uk")
    }

    func testCurrentWhisperCodeReflectsLiveChange() {
        let pref = LanguagePreference()
        pref.current = .french
        XCTAssertEqual(pref.currentWhisperCode(), "fr")
    }

    func testCurrentWhisperCodeFallsBackToEnglishOnGarbage() {
        let pref = LanguagePreference()
        UserDefaults.standard.set("not-a-language", forKey: LanguagePreference.key)
        XCTAssertEqual(pref.currentWhisperCode(), "en")
    }
}
