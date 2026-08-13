import Combine
import Foundation

/// The smoothed mic peak (0…1) behind the recording level meter, kept apart
/// from `AudioCaptureService` so that only the meter pays for its rate: it is
/// written from the audio tap ~10× a second, while everything else the service
/// publishes changes a handful of times a meeting.
///
/// Zeroed on pause, stop and mute — a meter still dancing when nothing is being
/// captured is a lie.
@MainActor
final class InputLevel: ObservableObject {
    @Published private(set) var value: Float = 0

    /// The hold is kept apart from `value` because `value` is deadbanded, and
    /// decaying off a deadbanded number stalls the fall: each step is a fifth
    /// of the level, so once the level is small the step lands inside the
    /// deadband, gets dropped, and the next buffer decays from the same
    /// unchanged number forever. The meter then sits at a fifth of full height
    /// through a silent room, which is the one thing it exists to rule out.
    private var heldPeak: Float = 0

    /// The hold never reaches zero on its own, and a muted tap rewrites the
    /// same zero every buffer — so an unfiltered setter republishes ~12×/s
    /// through silence, restarting the meter's 0.14s transaction on five
    /// capsules that are already where they belong.
    private static let silenceFloor: Float = 0.01
    private static let step: Float = 0.005
    private static let decay: Float = 0.8

    /// Decaying peak hold — rises instantly to a loud frame, eases back down so
    /// the meter doesn't strobe between buffers.
    func hold(peak: Float) {
        publish(max(peak, heldPeak * Self.decay))
    }

    func reset() {
        publish(0)
    }

    private func publish(_ level: Float) {
        heldPeak = level
        let settled = level < Self.silenceFloor ? 0 : level
        guard abs(settled - value) >= Self.step else { return }
        value = settled
    }
}
