import AppKit
import SwiftUI

/// The physical notch's own hit zone: a trackpad swipe up here tucks the
/// meeting bar away into the cut-out, a swipe down brings it back. Only ever
/// mounted where there is a real cut-out to tuck into
/// (`NotchGeometry.hasCutout`) — every other display never creates this view
/// at all, so there is no hidden hotspot, no scroll handling, nothing that
/// could misfire, exactly as a normal floating bar should behave.
///
/// A narrow `NSView` rather than a SwiftUI gesture: `DragGesture`/`MagnifyGesture`
/// read finger *position*, and a scroll wheel/trackpad swipe is reported as
/// `NSEvent.scrollWheel`, which SwiftUI does not expose a gesture for. This is
/// the whole reason a tiny native bridge exists here at all.
struct NotchGestureZone: NSViewRepresentable {
    let onSwipeUp: () -> Void
    let onSwipeDown: () -> Void

    func makeNSView(context: Context) -> NotchScrollGestureView {
        let view = NotchScrollGestureView()
        view.onSwipeUp = onSwipeUp
        view.onSwipeDown = onSwipeDown
        return view
    }

    func updateNSView(_ nsView: NotchScrollGestureView, context: Context) {
        nsView.onSwipeUp = onSwipeUp
        nsView.onSwipeDown = onSwipeDown
    }
}

/// Accumulates one trackpad gesture's vertical scroll distance and fires once
/// it crosses a threshold in either direction, once per gesture — a handful
/// of stray pixels (what a raw per-event delta would misfire on) never
/// triggers anything, and a gesture that already fired doesn't fire again on
/// the same continued swipe.
///
/// Reads `scrollingDeltaY` rather than the raw hardware `deltaY`: AppKit
/// already resolves that against the user's natural-scrolling preference, so
/// its sign is the direction the user actually intends, not whichever way the
/// trackpad's hardware happens to report.
final class NotchScrollGestureView: NSView {
    var onSwipeUp: (() -> Void)?
    var onSwipeDown: (() -> Void)?

    /// How far an accumulated gesture has to travel before it counts.
    private static let threshold: CGFloat = 48
    private var accumulated: CGFloat = 0
    private var firedThisGesture = false

    override func scrollWheel(with event: NSEvent) {
        Log.ui.info(
            "notch gesture: scrollWheel phase=\(String(describing: event.phase)) momentum=\(String(describing: event.momentumPhase)) deltaY=\(event.scrollingDeltaY)"
        )

        // Momentum is the OS still animating a gesture that already ended —
        // counting it would fire a second time off fingers that already left
        // the trackpad.
        guard event.momentumPhase == [] else { return }

        switch event.phase {
        case .began:
            accumulated = 0
            firedThisGesture = false
        case .changed:
            accumulate(event.scrollingDeltaY)
        case .ended, .cancelled:
            accumulated = 0
            firedThisGesture = false
        default:
            // A traditional scroll wheel reports no phase at all — still has
            // to work, just as a one-shot per event rather than an
            // accumulated gesture.
            accumulate(event.scrollingDeltaY)
        }
    }

    /// NOTE: sign convention (negative accumulated = swipe up = hide,
    /// positive = swipe down = reveal) is the natural reading of
    /// `scrollingDeltaY` but has not been confirmed on real trackpad
    /// hardware. If up/down land backwards in testing, swap the two branches
    /// below — nothing else in the gesture pipeline depends on which way
    /// round this is.
    private func accumulate(_ delta: CGFloat) {
        guard !firedThisGesture else { return }
        accumulated += delta
        if accumulated <= -Self.threshold {
            firedThisGesture = true
            onSwipeUp?()
        } else if accumulated >= Self.threshold {
            firedThisGesture = true
            onSwipeDown?()
        }
    }
}
