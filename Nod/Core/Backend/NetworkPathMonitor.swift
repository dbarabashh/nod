import Foundation
import Network

/// Thin wrapper over `NWPathMonitor` that reports connectivity as edge
/// transitions rather than a poll.
///
/// Used to drain the transcription retry queue the instant the link returns
/// (NOD-29). We react to `NWPathMonitor` events instead of probing reachability
/// before each send: a pre-flight probe is a TOCTOU race (TN3151) — the link can
/// drop between the check and the send — so the send always just attempts, and
/// this monitor only decides *when to retry* what already failed.
///
/// `@unchecked Sendable`: the sole mutable state (`isSatisfied` and the `monitor`
/// handle) is touched only on `queue` (the monitor's update handler) and the
/// synchronous `start`/`cancel` calls, which the owner (`TranscriptStore`)
/// serialises with its own start/stop lifecycle.
final class NetworkPathMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "nod.network.path")
    /// Recreated on every `start`: an `NWPathMonitor` can't be restarted once
    /// cancelled, and the owner starts/stops it per meeting.
    private var monitor: NWPathMonitor?

    /// The last observed path status. Optimistically `true` before the first
    /// callback so nothing gates on a spurious "offline" during startup.
    private(set) var isSatisfied = true

    /// Fired on `queue` only when the satisfied state *flips*, with the new value.
    var onChange: ((Bool) -> Void)?

    func start() {
        guard monitor == nil else { return }
        // Fresh cycle: forget the previous run's last status so a stale
        // `unsatisfied` can't fire a spurious transition on the first callback.
        isSatisfied = true
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            guard satisfied != isSatisfied else { return }
            isSatisfied = satisfied
            Log.stt.info("network path \(satisfied ? "satisfied" : "unsatisfied")")
            onChange?(satisfied)
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor?.cancel()
        monitor = nil
    }

    deinit {
        // An owner released without a matching stop()/cancel() must not leak the
        // running monitor and its dispatch source. NWPathMonitor.cancel() is safe
        // from any thread.
        monitor?.cancel()
    }
}
