import XCTest
@testable import Nod

final class VoiceOpenActionsTests: XCTestCase {
    // MARK: - validatedURL

    func testHTTPSURLIsAccepted() {
        XCTAssertEqual(
            VoiceOpenActions.validatedURL("https://linear.app/nod/issue/NOD-1"),
            URL(string: "https://linear.app/nod/issue/NOD-1")
        )
    }

    func testHTTPURLIsAccepted() {
        XCTAssertNotNil(VoiceOpenActions.validatedURL("http://example.com"))
    }

    func testFileSchemeIsRejected() {
        XCTAssertNil(VoiceOpenActions.validatedURL("file:///Users/dima/secrets.txt"))
    }

    func testJavascriptSchemeIsRejected() {
        XCTAssertNil(VoiceOpenActions.validatedURL("javascript:alert(1)"))
    }

    func testCustomSchemeIsRejected() {
        XCTAssertNil(VoiceOpenActions.validatedURL("slack://open"))
    }

    func testSchemelessTextIsRejected() {
        XCTAssertNil(VoiceOpenActions.validatedURL("linear.app/nod"))
    }

    func testHostlessURLIsRejected() {
        XCTAssertNil(VoiceOpenActions.validatedURL("https:///path"))
    }

    // MARK: - resolveApplication

    private func withFakeApps(_ names: [String], _ body: (URL) -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in names {
            try? FileManager.default.createDirectory(
                at: root.appendingPathComponent("\(name).app"),
                withIntermediateDirectories: true
            )
        }
        body(root)
    }

    func testExactNameResolves() {
        withFakeApps(["Slack", "System Settings"]) { root in
            let resolved = VoiceOpenActions.resolveApplication(named: "Slack", in: [root])
            XCTAssertEqual(resolved?.lastPathComponent, "Slack.app")
        }
    }

    func testCaseInsensitiveNameResolves() {
        withFakeApps(["Slack"]) { root in
            let resolved = VoiceOpenActions.resolveApplication(named: "slack", in: [root])
            XCTAssertEqual(resolved?.lastPathComponent, "Slack.app")
        }
    }

    func testPartialNamePrefersExactOverPartial() {
        withFakeApps(["Settings Sync Helper", "System Settings"]) { root in
            let resolved = VoiceOpenActions.resolveApplication(named: "System Settings", in: [root])
            XCTAssertEqual(resolved?.lastPathComponent, "System Settings.app")
        }
    }

    func testPartialNameMatchesWhenNoExactApp() {
        withFakeApps(["System Settings"]) { root in
            let resolved = VoiceOpenActions.resolveApplication(named: "Settings", in: [root])
            XCTAssertEqual(resolved?.lastPathComponent, "System Settings.app")
        }
    }

    func testUnknownAppResolvesToNil() {
        withFakeApps(["Slack"]) { root in
            XCTAssertNil(VoiceOpenActions.resolveApplication(named: "Nonexistent App", in: [root]))
        }
    }

    func testBlankNameResolvesToNil() {
        withFakeApps(["Slack"]) { root in
            XCTAssertNil(VoiceOpenActions.resolveApplication(named: "   ", in: [root]))
        }
    }
}
