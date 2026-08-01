import CoreGraphics

/// Compact vs wide footprint of the floating capture panel.
///
/// A shared layout token rather than a constant on the panel's own view: the
/// window that sizes the panel, the view that lays it out, and the detection
/// card that matches its width all read it, and the last of those is a feature
/// that has no business reaching into the app shell for a number.
enum PanelWidth {
    static let compact: CGFloat = 320
    static let wide: CGFloat = 640
}
