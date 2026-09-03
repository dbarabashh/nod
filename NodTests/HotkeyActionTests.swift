import Carbon.HIToolbox
import XCTest
@testable import Nod

final class HotkeyActionTests: XCTestCase {
    func testEveryActionHasItsOwnCarbonID() {
        let ids = HotkeyAction.allCases.map(\.hotKeyID)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertFalse(ids.contains(1), "1 belonged to the retired Suggest-reply binding")
    }

    func testEveryActionHasItsOwnDefaultCombo() {
        let combos = HotkeyAction.allCases.map(\.defaultCombo)
        XCTAssertEqual(Set(combos.map(\.displayString)).count, combos.count)
    }

    func testHoldToAskDefaultsToCommandT() {
        XCTAssertEqual(HotkeyAction.holdToAsk.defaultCombo.displayString, "⌘T")
    }

    func testEveryActionRoundTripsThroughItsID() {
        for action in HotkeyAction.allCases {
            XCTAssertEqual(HotkeyAction(hotKeyID: action.hotKeyID), action)
        }
    }
}

final class SpokenLanguageTests: XCTestCase {
    @MainActor
    func testWhisperCodesAndNamesBothResolve() {
        XCTAssertEqual(NotchModel.spokenLanguage("uk"), .ukrainian)
        XCTAssertEqual(NotchModel.spokenLanguage("ukrainian"), .ukrainian)
        XCTAssertEqual(NotchModel.spokenLanguage("English"), .english)
        XCTAssertEqual(NotchModel.spokenLanguage("Mandarin Chinese"), .mandarin)
        XCTAssertEqual(NotchModel.spokenLanguage("chinese"), .mandarin)
        XCTAssertEqual(NotchModel.spokenLanguage("zh-CN"), .mandarin)
        XCTAssertEqual(NotchModel.spokenLanguage("pt-BR"), .portuguese)
        XCTAssertNil(NotchModel.spokenLanguage("swahili"))
        XCTAssertNil(NotchModel.spokenLanguage(nil))
    }
}
