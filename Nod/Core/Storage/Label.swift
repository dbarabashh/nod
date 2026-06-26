import SwiftUI

/// A user-defined label that groups sessions thematically ("Pricing", "1:1s").
/// Wire-compatible with the `labels` table (`20260603211050_labels.sql`).
/// De-duped per user on `lower(name)`. `color` is an `#RRGGBB` hex string.
struct SessionLabel: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let userID: UUID
    let name: String
    let color: String
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case name
        case color
        case createdAt = "created_at"
    }

    /// Omit `createdAt` on insert so Postgres' `default now()` populates it.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(userID, forKey: .userID)
        try c.encode(name, forKey: .name)
        try c.encode(color, forKey: .color)
    }

    /// The label's colour as a SwiftUI `Color`, falling back to the brand
    /// violet for a malformed hex string.
    var swatchColor: Color {
        Self.color(fromHex: color) ?? Theme.Palette.violet
    }

    static func color(fromHex hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return Color(hex: value)
    }
}

/// The fixed palette users pick from when creating a label — drawn from the
/// design system so labels read as part of the app, not arbitrary colours.
enum LabelPalette {
    static let swatches: [String] = [
        "#8B5CF6", // violet
        "#EC4899", // pink
        "#22D3EE", // cyan
        "#F59E0B", // gold
        "#22C55E", // green
        "#EF4444", // red
        "#3B82F6", // blue
        "#70757C" // slate
    ]

    static let `default` = swatches[0]
}
