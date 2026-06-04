import Combine
import Foundation
import Supabase

/// Server-driven update gate. On launch it reads the single `app_config` row
/// and compares the running `AppVersion.build` against two thresholds:
///
/// - below `minimum_build`  → `.required`: a blocking screen, because a
///   backend change has (or soon will) break this build.
/// - below `recommended_build` → `.recommended`: a dismissible nudge.
///
/// The proxy is the backstop: if a stale client slips past the launch check
/// and the `llm-proxy` rejects it with 426, `OpenRouterClient` posts
/// `.nodUpdateRequired` and we flip to `.required` from anywhere.
@MainActor
final class UpdateGate: ObservableObject {
    enum Status: Equatable {
        case ok
        case recommended(latestBuild: Int)
        case required
    }

    @Published private(set) var status: Status = .ok

    private let supabase: SupabaseClient?
    private static let tableName = "app_config"
    private static let dismissedKey = "update.recommendedDismissedBuild"

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
        let recommendedBuild: Int

        enum CodingKeys: String, CodingKey {
            case minimumBuild = "minimum_build"
            case recommendedBuild = "recommended_build"
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
        if AppVersion.build < config.minimumBuild {
            return .required
        }
        if AppVersion.build < config.recommendedBuild,
           UserDefaults.standard.integer(forKey: Self.dismissedKey) < config.recommendedBuild {
            return .recommended(latestBuild: config.recommendedBuild)
        }
        return .ok
    }

    /// Dismiss the recommended nudge for this build so it doesn't re-nag until
    /// a newer one ships.
    func dismissRecommended() {
        if case let .recommended(latestBuild) = status {
            UserDefaults.standard.set(latestBuild, forKey: Self.dismissedKey)
        }
        status = .ok
    }

    /// Hand off to Sparkle (owned by AppDelegate) to fetch + install.
    func startUpdate() {
        NotificationCenter.default.post(name: .nodCheckForUpdates, object: nil)
    }
}

extension Notification.Name {
    /// Posted by `OpenRouterClient` when the proxy returns 426 — a stale
    /// client that slipped past the launch check.
    static let nodUpdateRequired = Notification.Name("nod.update.required")
    /// Posted by `UpdateGate` to ask AppDelegate's Sparkle controller to run.
    static let nodCheckForUpdates = Notification.Name("nod.update.checkForUpdates")
}
