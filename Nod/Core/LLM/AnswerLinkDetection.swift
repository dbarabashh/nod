import Foundation
import SwiftUI

/// Whether an answer carries something a voice can't actually hand over: a
/// URL. The spoken pipeline is told never to read a link aloud
/// (`speech.ts`'s `PERSONA`), so an answer that has one has to be shown, not
/// just said — this is the check voice-ask uses to decide that.
enum AnswerLinkDetection {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func containsLink(_ text: String) -> Bool {
        guard let detector else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, range: range) != nil
    }

    /// The same text with every URL clickable and short enough to sit in the
    /// notch, whose answer column is a couple of hundred points wide.
    ///
    /// A pasted URL is drawn whole today, so one Notion page id took three of
    /// the four lines the panel has. The address is not the information — the
    /// destination is — so the host stands in for it and the full URL rides on
    /// the link attribute, where a click and a hover both still reach it.
    static func linked(_ text: String) -> AttributedString {
        guard let detector else { return AttributedString(text) }
        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, range: range)
        guard !matches.isEmpty else { return AttributedString(text) }

        var result = AttributedString()
        var cursor = text.startIndex
        for match in matches {
            guard let matched = Range(match.range, in: text), let url = match.url else { continue }
            result.append(AttributedString(String(text[cursor ..< matched.lowerBound])))
            var link = AttributedString(label(for: url))
            link.link = url
            link.underlineStyle = Text.LineStyle.single
            result.append(link)
            cursor = matched.upperBound
        }
        result.append(AttributedString(String(text[cursor...])))
        return result
    }

    /// `app.notion.com/…` — enough to recognise where it goes, never enough to
    /// wrap. The ellipsis is only there when a path was dropped, so a bare
    /// domain doesn't claim to be hiding something.
    private static func label(for url: URL) -> String {
        guard let host = url.host()?.replacingOccurrences(of: "www.", with: ""), !host.isEmpty else {
            return url.absoluteString
        }
        let path = url.path()
        return path.isEmpty || path == "/" ? host : "\(host)/…"
    }
}
