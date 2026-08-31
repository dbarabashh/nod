import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

/// Reads a window's text off the pixels, for the windows the accessibility tree
/// can't describe.
///
/// Electron and canvas-drawn apps — Slack, Figma, Notion — expose almost
/// nothing through accessibility: a Slack channel comes back as its own chrome,
/// 150 characters of sidebar, and none of the conversation. This is the
/// fallback for exactly those, and only those.
///
/// The image never leaves memory: it is recognised and dropped in the same
/// call. Nothing is written to disk and nothing but the resulting text is
/// stored — the claim in `docs/policies/privacy.md` § 3.10 depends on that
/// staying true.
enum ScreenTextRecognizer {
    /// Below this a "window" is a palette or a toolbar, and recognising it
    /// costs more than it returns.
    private static let minimumWindowSide: CGFloat = 200

    /// Vision returns a candidate for anything that resembles glyphs — icon
    /// edges, gradients, window chrome — and the low-confidence ones are noise
    /// that ends up in the prompt as though it were content. Dropping them is
    /// the difference between reading a window and reading its artefacts.
    private static let minimumConfidence: Float = 0.35

    /// Single-window capture is `SCScreenshotManager`, which is macOS 14+.
    /// On 13 the fallback simply doesn't exist and accessibility stands alone —
    /// the deployment target isn't moving for a fallback.
    static var isSupported: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    /// Whether a pixel read is possible at all. Never prompts: the grant is
    /// asked for where the user expects it, not silently mid-capture.
    static var isAvailable: Bool {
        isSupported && CGPreflightScreenCaptureAccess()
    }

    /// The frontmost window of a process, read as text, or nothing when it has
    /// no readable window, the blocklist rejects it, the grant is missing, or
    /// the OS is too old.
    ///
    /// `isAllowed` is the blocklist, and it is consulted **before** the image is
    /// taken — a window the user excluded is never captured, only skipped.
    static func read(
        forProcessID pid: pid_t,
        matching expectedTitle: String = "",
        isAllowed: @Sendable (String) -> Bool
    ) async -> (title: String, texts: [String])? {
        guard #available(macOS 14.0, *), isAvailable else { return nil }
        guard let found = await frontmostWindow(forProcessID: pid, matching: expectedTitle) else { return nil }
        let title = found.window.title ?? ""
        guard isAllowed(title) else { return nil }
        guard let image = await image(of: found.window, among: found.displays) else { return nil }
        let texts = await Task.detached(priority: .utility) { recognize(image) }.value
        return texts.isEmpty ? nil : (title, texts)
    }

    /// The window the user is in, not merely the first one big enough.
    ///
    /// `SCShareableContent.windows` is in no documented order, so picking
    /// `first` meant a dialog, a huddle, or a second document could be captured
    /// and then stored under the focused window's title — content filed against
    /// the wrong window, which no later pass can undo. Accessibility already
    /// named the focused window, so match on that title first. Failing that,
    /// the lowest `windowLayer` is the ordinary document level, which is what
    /// separates a document from the floating palettes and panels above it.
    @available(macOS 14.0, *)
    private static func frontmostWindow(
        forProcessID pid: pid_t,
        matching expectedTitle: String
    ) async -> (window: SCWindow, displays: [SCDisplay])? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let candidates = content.windows.filter { window in
                window.owningApplication?.processID == pid
                    && window.frame.width >= minimumWindowSide
                    && window.frame.height >= minimumWindowSide
            }
            if !expectedTitle.isEmpty, let named = candidates.first(where: { $0.title == expectedTitle }) {
                return (named, content.displays)
            }
            return candidates.min { $0.windowLayer < $1.windowLayer }.map { ($0, content.displays) }
        } catch {
            Log.screen.error("context: window lookup failed — \(error.localizedDescription)")
            return nil
        }
    }

    /// The window as pixels, from whichever filter this display arrangement
    /// accepts.
    ///
    /// `desktopIndependentWindow` resolves the window's display itself, and on
    /// a second display that lookup fails outright — `failed display lookup for
    /// windowBounds={{-1524, 33}, …} found=0`, and every pixel read of a window
    /// over there returns nothing. The display-scoped filter names the display
    /// instead of asking ScreenCaptureKit to find it, so it is tried second
    /// rather than first: the single-display path is the one that works today
    /// and must not be disturbed to fix the one that doesn't.
    @available(macOS 14.0, *)
    private static func image(of window: SCWindow, among displays: [SCDisplay]) async -> CGImage? {
        if let image = await image(of: window, using: SCContentFilter(desktopIndependentWindow: window)) {
            return image
        }
        guard let display = display(hosting: window, among: displays) else {
            Log.screen.error("context: window capture failed and no display hosts the window")
            return nil
        }
        // The display filter draws the whole display with only this window
        // composited onto it, so the crop is what makes the result a window
        // again. `sourceRect` is display-local, hence the shift by its origin.
        let filter = SCContentFilter(display: display, including: [window])
        let cropped = rect(ofWindow: window.frame, within: display.frame)
        guard let image = await image(of: window, using: filter, cropping: cropped) else {
            Log.screen.error("context: window capture failed on both filters — display \(display.displayID)")
            return nil
        }
        return image
    }

    @available(macOS 14.0, *)
    private static func display(hosting window: SCWindow, among displays: [SCDisplay]) -> SCDisplay? {
        indexOfHost(forWindow: window.frame, among: displays.map(\.frame)).map { displays[$0] }
    }

    /// Which display the window sits on: the one it overlaps most, because a
    /// window dragged across a seam belongs to neither outright and the larger
    /// share is the one that has its text on it.
    static func indexOfHost(forWindow window: CGRect, among displays: [CGRect]) -> Int? {
        displays.indices
            .map { (index: $0, overlap: displays[$0].intersection(window)) }
            .filter { !$0.overlap.isEmpty }
            .max { $0.overlap.width * $0.overlap.height < $1.overlap.width * $1.overlap.height }?
            .index
    }

    /// The window's frame in its display's own coordinates, which is what
    /// `sourceRect` is measured in.
    static func rect(ofWindow window: CGRect, within display: CGRect) -> CGRect {
        window.offsetBy(dx: -display.minX, dy: -display.minY)
    }

    @available(macOS 14.0, *)
    private static func image(
        of window: SCWindow,
        using filter: SCContentFilter,
        cropping sourceRect: CGRect? = nil
    ) async -> CGImage? {
        let configuration = SCStreamConfiguration()
        if let sourceRect {
            configuration.sourceRect = sourceRect
        }
        // `frame` is in points; the backing store on a Retina display is
        // `pointPixelScale` times that. Capturing at the point size threw away
        // half the linear resolution before recognition ever ran — on 11pt chat
        // text, which is the whole reason this fallback exists.
        // Floored at 1: a zero scale would make the configured size zero and
        // turn every pixel read into a silent no-op, which is the one failure
        // mode here that leaves no trace.
        let scale = max(1, CGFloat(filter.pointPixelScale))
        let pixels = CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
        let fitted = downscaledToLongSideLimit(pixels)
        configuration.width = Int(fitted.width)
        configuration.height = Int(fitted.height)
        configuration.showsCursor = false
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            // Debug, not error: the window-scoped attempt failing is the normal
            // first half of a capture on a second display, and the caller logs
            // once when both filters have been tried.
            Log.screen.debug("context: capture attempt failed — \(error.localizedDescription)")
            return nil
        }
    }

    /// Ceiling on the captured image's long side.
    ///
    /// Recognition cost scales with pixel count, so taking the full backing
    /// store of a 6K display would trade the CPU budget away for resolution far
    /// past what text recognition can use. Above this the extra pixels buy
    /// nothing legible.
    private static let maximumLongSide: CGFloat = 4_096

    static func downscaledToLongSideLimit(_ size: CGSize) -> CGSize {
        let longSide = max(size.width, size.height)
        guard longSide > maximumLongSide, longSide > 0 else { return size }
        let factor = maximumLongSide / longSide
        return CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
    }

    /// Pinned rather than left to the default, which travels with the OS. An
    /// unpinned revision silently changes what gets recognised — and so what
    /// gets stored under the user — across a macOS update, with nothing in the
    /// record saying the reading changed.
    private static let revision = VNRecognizeTextRequestRevision3

    /// The languages Vision is asked to look for, resolved once against what
    /// the installed revision actually supports.
    ///
    /// This was a hardcoded `en-US`/`uk-UA` pair, which recognised a German or
    /// Spanish window with the wrong model and no sign that it had. The
    /// system's own language order is the closest available statement of what
    /// the user reads. `AppLanguage` is deliberately not consulted: it is an
    /// *output* preference, and recognition is an input constraint — the same
    /// distinction transcription observes.
    private static let recognitionLanguages: [String] = {
        let probe = VNRecognizeTextRequest()
        probe.revision = revision
        guard let supported = try? probe.supportedRecognitionLanguages(), !supported.isEmpty else {
            return ["en-US"]
        }
        var picked: [String] = []
        // English last-resort as well as first-class: identifiers, code and
        // product chrome are English on a screen in any locale.
        let preferred = Locale.preferredLanguages + ["en"]
        for identifier in preferred where picked.count < maximumRecognitionLanguages {
            let code = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? identifier
            guard let match = supported.first(where: { $0.hasPrefix(code) }), !picked.contains(match) else { continue }
            picked.append(match)
        }
        return picked.isEmpty ? ["en-US"] : picked
    }()

    /// Ceiling on how many languages `.accurate` is asked to consider. Someone
    /// with eight languages configured would otherwise pay for eight models on
    /// a path that already has to stay off the steady state.
    private static let maximumRecognitionLanguages = 3

    private static func recognize(_ image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.revision = revision
        request.recognitionLevel = .accurate
        // A window is labels, code and identifiers, not prose: "correcting"
        // AP-8 or cc-analytics into a dictionary word destroys the only part of
        // the capture worth keeping.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = recognitionLanguages

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            Log.screen.error("context: OCR failed — \(error.localizedDescription)")
            return []
        }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= minimumConfidence
            else { return nil }
            return candidate.string
        }
    }
}
