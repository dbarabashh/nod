import Foundation

/// Postgres and Google both emit ISO 8601, with or without fractional seconds;
/// one `ISO8601DateFormatter` refuses whichever shape it wasn't configured for.
enum ServerTimestamp {
    static func date(from raw: String) -> Date? {
        withFractional.date(from: raw) ?? plain.date(from: raw)
    }

    private static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain = ISO8601DateFormatter()
}
