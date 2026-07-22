import AppKit
import Supabase
import SwiftUI
import XCTest
@testable import Nod

/// Renders the privacy pane for real. A settings pane that crashes on open is
/// invisible to logic tests — only laying it out catches it.
@MainActor
final class ScreenPrivacySectionRenderTests: XCTestCase {
    private func render(_ view: some View) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 600)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    private func makeExclusions() -> ScreenExclusions {
        let suite = "screen.privacy.render.\(UUID().uuidString)"
        return ScreenExclusions(defaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    func testRendersWhenNothingIsExcluded() {
        render(ScreenPrivacySection(exclusions: makeExclusions()))
    }

    /// Mirrors `SettingsView.detail`: the pane lives in a scroll view that
    /// offers unbounded width, which is where a view that asks for its ideal
    /// size can go wrong.
    func testRendersInsideTheSettingsDetailContainer() {
        let exclusions = makeExclusions()
        exclusions.exclude(ExcludedApp(bundleID: "us.zoom.xos", name: "Zoom"))
        exclusions.excludeWebsite("bank.com")

        render(
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Privacy")
                    ScreenPrivacySection(exclusions: exclusions)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
            }
        )
    }

    /// The whole Privacy pane as `SettingsView` composes it — the screen
    /// controls stacked above the GDPR data section. Renders the combination,
    /// not just the new part.
    func testRendersTheWholePrivacyPane() {
        let supabase = SupabaseClient(supabaseURL: SupabaseConfig.url, supabaseKey: SupabaseConfig.anonKey)
        let auth = AuthService(client: supabase)
        let export = AccountExportService(supabase: supabase)
        let exclusions = makeExclusions()
        exclusions.exclude(ExcludedApp(bundleID: "us.zoom.xos", name: "Zoom"))
        exclusions.excludeWebsite("bank.com")

        render(
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Privacy")
                    VStack(alignment: .leading, spacing: 20) {
                        ScreenPrivacySection(exclusions: exclusions)
                        AccountDataSection(auth: auth, export: export)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
            }
        )
    }

    func testRendersWithExcludedAppsAndWebsites() {
        let exclusions = makeExclusions()
        exclusions.exclude(ExcludedApp(bundleID: "us.zoom.xos", name: "Zoom"))
        exclusions.exclude(ExcludedApp(bundleID: "com.apple.Safari", name: "Safari"))
        exclusions.excludeWebsite("bank.com")

        render(ScreenPrivacySection(exclusions: exclusions))
    }
}
