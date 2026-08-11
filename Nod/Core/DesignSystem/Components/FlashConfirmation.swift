import SwiftUI

/// Set a confirmation state, hold it for `seconds`, then animate it back.
///
/// Shared so every "Copied" / "Shared" check in the app flashes for the same
/// length and with the same easing — the meeting detail view's copy and share
/// buttons and the notch recap card's copy all run through here. A tweak to the
/// timing belongs in one place; when it lived inside one view, the next surface
/// that needed it re-typed the constants and they drifted.
@MainActor
func flashConfirmation(set: () -> Void, reset: () -> Void, for seconds: Double) async {
    withAnimation(.easeOut(duration: 0.15), set)
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    withAnimation(.easeOut(duration: 0.2), reset)
}
