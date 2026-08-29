import Foundation

/// Where the Appearance settings are stored.
///
/// The keys live in `Core` and the preference object that owns them lives in
/// `Features/Settings/`, because the surfaces that read the transparency
/// switch — `BackdropSurface` and everything it wraps — are `Core` components
/// spread across four separate hosting roots. No injected object reaches all
/// of them; a defaults key does, and `Core` may not import a feature to get it.
enum AppearanceDefaults {
    static let modeKey = "appearance.mode"
    static let transparencyKey = "appearance.transparency"
    static let isTransparentByDefault = true
}
