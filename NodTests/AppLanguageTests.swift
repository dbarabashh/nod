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
}
