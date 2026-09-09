import Foundation

/// Whether an answer carries something a voice can't actually hand over: a
/// URL. The spoken pipeline is told never to read a link aloud
/// (`speech.ts`'s `PERSONA`), so an answer that has one has to be shown, not
/// just said — this is the check voice-ask uses to decide that.
enum AnswerLinkDetection {
    /// Shared with `AnswerLinkText`: whether an answer has a link and how that
    /// link is drawn are two halves of one question, and two detectors built
    /// from two copies of the checking types can answer them differently.
    static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func containsLink(_ text: String) -> Bool {
        guard let detector else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, range: range) != nil
    }
}
