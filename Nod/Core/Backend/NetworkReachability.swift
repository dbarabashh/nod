import Combine
import Foundation

/// The link's state, published for the UI.
///
/// Deliberately not a pre-flight gate. `NetworkPathMonitor` exists because
/// probing reachability before a send is a TOCTOU race (TN3151) — the link can
/// drop between the check and the send — so nothing here decides whether to
/// try. It decides when to pick up again what already failed, and lets a
/// failure say "you're offline" instead of blaming Nod.
@MainActor
final class NetworkReachability: ObservableObject {
    @Published private(set) var isOnline = true

    private let monitor = NetworkPathMonitor()

    init() {
        monitor.onChange = { [weak self] satisfied in
            Task { @MainActor in self?.isOnline = satisfied }
        }
        monitor.start()
    }

    deinit {
        monitor.cancel()
    }
}
