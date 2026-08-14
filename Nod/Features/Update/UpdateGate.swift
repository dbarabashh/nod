import Combine
import Foundation
import Supabase

/// Server-driven update gate. On launch it reads this platform's `app_config`
/// row and compares the running `AppVersion.build` against two thresholds:
///
/// Below `minimum_build` → `.required`: the notch blocks a capture from
/// starting, because a backend change has (or soon will) break this build.
/// `recommended_build` is read but no longer surfaced — Sparkle raises its own
/// prompt for a non-blocking update, and two nudges for one thing is one too
/// many.
///
/// The proxy is the backstop: if a stale client slips past the launch check
/// and the `llm-proxy` rejects it with 426, `LLMProxyClient` posts
/// `.nodUpdateRequired` and we flip to `.required` from anywhere.
@MainActor
final class UpdateGate: ObservableObject {
    enum Status: Equatable {
        case ok
        case required
    }

    @Published private(set) var status: Status = .ok

    private let supabase: SupabaseClient?
    private static let tableName = "app_config"

    init(supabase: SupabaseClient?) {
        self.supabase = supabase
        NotificationCenter.default.addObserver(
            forName: .nodUpdateRequired,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.status = .required }
        }
    }

    private struct AppConfig: Decodable {
        let minimumBuild: Int

        enum CodingKeys: String, CodingKey {
            case minimumBuild = "minimum_build"
        }
    }

    /// Reads the config and resolves the launch status. A required gate is
    /// never downgraded — if the proxy already flipped us to `.required`,
    /// a softer config result can't override it.
    func check() async {
        guard let supabase else { return }
        do {
            let rows: [AppConfig] = try await supabase
                .from(Self.tableName)
                .select()
                .eq("platform", value: AppVersion.platform)
                .limit(1)
                .execute()
                .value
            guard let config = rows.first else { return }
            if status == .required { return }
            status = resolve(config)
        } catch {
            // A config the client can't reach must never block usage — fail open.
            Log.ui.error("UpdateGate.check failed: \(error.localizedDescription)")
        }
    }

    private func resolve(_ config: AppConfig) -> Status {
        AppVersion.build < config.minimumBuild ? .required : .ok
    }

    /// Hand off to Sparkle (owned by AppDelegate) to fetch + install.
    func startUpdate() {
        NotificationCenter.default.post(name: .nodCheckForUpdates, object: nil)
    }
}

extension Notification.Name {
    /// Posted by `LLMProxyClient` when the proxy returns 426 — a stale
    /// client that slipped past the launch check.
    static let nodUpdateRequired = Notification.Name("nod.update.required")
    /// Posted by `UpdateGate` to ask AppDelegate's Sparkle controller to run.
    static let nodCheckForUpdates = Notification.Name("nod.update.checkForUpdates")
}
