import AppKit
import XCTest
@testable import Nod

@MainActor
final class AppearancePreferenceTests: XCTestCase {
    private func defaults(_ name: String = #function) throws -> UserDefaults {
        let suite = "nod.tests.appearance.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    func testDefaultsToTheSystemTheme() throws {
        XCTAssertEqual(try AppearancePreference(defaults: defaults()).mode, .system)
    }

    /// A fresh install paints solid windows. The blur is an opt-in, not the
    /// thing a person has to find the switch to turn off.
    func testTransparencyIsOffUntilChosen() {
        XCTAssertFalse(AppearanceDefaults.isTransparentByDefault)
    }

    func testTheChoiceSurvivesARelaunch() throws {
        let store = try defaults()
        AppearancePreference(defaults: store).mode = .light
        XCTAssertEqual(AppearancePreference(defaults: store).mode, .light)
    }

    /// nil is not "no opinion left over from last launch" — it is what tells
    /// AppKit to follow System Settings.
    func testSystemModeInheritsRatherThanPinningAnAppearance() {
        XCTAssertNil(AppearancePreference.Mode.system.appearance)
        XCTAssertEqual(AppearancePreference.Mode.light.appearance?.name, .aqua)
        XCTAssertEqual(AppearancePreference.Mode.dark.appearance?.name, .darkAqua)
    }
}
