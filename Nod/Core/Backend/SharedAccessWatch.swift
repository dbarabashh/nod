import AppKit
import Foundation

/// Keeps membership and shared folders current while somebody is looking.
///
/// Access here is granted and revoked on a *different Mac* — a colleague shares
/// a folder, an administrator removes a member — and nothing in this process is
/// party to that. Until it asks again, the sidebar keeps drawing a project the
/// person no longer has, and clicking it shows sessions cached from when they
/// did. The rows are unreachable on the server the instant the share row goes,
/// so this is a display that lies rather than a leak, but a display that lies
/// about access is not much better.
///
/// Polling rather than Realtime, and not only because Realtime is absent from
/// this app. `postgres_changes` filters events through the same row-level
/// security as a query, so the person who just lost access to a row is exactly
/// the person no longer entitled to hear about it. A channel that requires the
/// access cannot be relied on to announce its removal — revocation, the case
/// that matters most, is the one it would drop.
///
/// Only while the app is frontmost. Nobody needs a fresh sidebar behind another
/// window, and a laptop lid should not keep a timer alive.
@MainActor
final class SharedAccessWatch {
    private static let interval: TimeInterval = 45

    private let organizations: OrganizationService
    private let labels: LabelStore
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(organizations: OrganizationService, labels: LabelStore) {
        self.organizations = organizations
        self.labels = labels
    }

    func start() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resume() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.suspend() }
        })
        if NSApp.isActive { resume() }
    }

    deinit {
        task?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func resume() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await organizations.refresh()
                await labels.refresh()
            }
        }
    }

    private func suspend() {
        task?.cancel()
        task = nil
    }
}
