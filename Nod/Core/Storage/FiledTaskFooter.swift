import Foundation

/// The provenance line every task filed from a meeting carries, whichever
/// path filed it.
///
/// A ticket is read by somebody with none of the meeting in their head. The
/// footer is what lets them get it back: the words that produced the task and
/// a link that opens the session in Nod. Never the share link — that one is
/// public, and a ticket is read by people the session was never shared with.
enum FiledTaskFooter {
    /// Long enough for the sentence that produced the task, short enough that
    /// the footer stays a footer.
    static let quoteLimit = 200

    /// With the year: a ticket is read months later, when "8 Sep" no longer
    /// says which one.
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    /// The app's own scheme, as `AuthService.callbackURL` declares it per build.
    static func deepLink(meetingID: UUID, scheme: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "meeting"
        components.queryItems = [URLQueryItem(name: "id", value: meetingID.uuidString)]
        guard let url = components.url else {
            fatalError("a scheme, a fixed host and one uuid query item always form a URL")
        }
        return url
    }

    static func text(meetingTitle: String, meetingDate: String, quote: String?, link: URL) -> String {
        var lines = ["—", "From “\(meetingTitle)” (\(meetingDate)), via Nod"]
        if let quote = quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty {
            let cut = quote.count > quoteLimit ? String(quote.prefix(quoteLimit)) + "…" : quote
            lines.append("> \(cut)")
        }
        lines.append(link.absoluteString)
        return lines.joined(separator: "\n")
    }

    /// The description with the footer under it, blank-line separated. An
    /// empty description is just the footer.
    static func appended(to description: String, footer: String) -> String {
        let body = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? footer : body + "\n\n" + footer
    }
}
