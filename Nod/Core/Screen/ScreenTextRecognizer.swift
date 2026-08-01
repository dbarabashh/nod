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
        isAllowed: @Sendable (String) -> Bool
    ) async -> (title: String, texts: [String])? {
        guard #available(macOS 14.0, *), isAvailable else { return nil }
        guard let window = await frontmostWindow(forProcessID: pid) else { return nil }
        let title = window.title ?? ""
        guard isAllowed(title) else { return nil }
        guard let image = await image(of: window) else { return nil }
        let texts = await Task.detached(priority: .utility) { recognize(image) }.value
        return texts.isEmpty ? nil : (title, texts)
    }

    @available(macOS 14.0, *)
    private static func frontmostWindow(forProcessID pid: pid_t) async -> SCWindow? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            return content.windows.first { window in
                window.owningApplication?.processID == pid
                    && window.frame.width >= minimumWindowSide
                    && window.frame.height >= minimumWindowSide
            }
        } catch {
            Log.screen.error("context: window lookup failed — \(error.localizedDescription)")
            return nil
        }
    }

    @available(macOS 14.0, *)
    private static func image(of window: SCWindow) async -> CGImage? {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width)
        configuration.height = Int(window.frame.height)
        configuration.showsCursor = false
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: configuration
            )
        } catch {
            Log.screen.error("context: window capture failed — \(error.localizedDescription)")
            return nil
        }
    }

    private static func recognize(_ image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // A window is labels, code and identifiers, not prose: "correcting"
        // AP-8 or cc-analytics into a dictionary word destroys the only part of
        // the capture worth keeping.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US", "uk-UA"]

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
