import Combine
import CoreGraphics
import Foundation

/// Persisted width of the main window's context column. One global width
/// applies everywhere (so resizing in any session carries over), with an
/// optional per-session override: dragging in a specific session remembers that
/// session's width, while sessions you've never resized — and the attention
/// column — follow the global. Double-clicking the divider clears the override.
///
/// The UserDefaults keys still say `chat.dock` on purpose: renaming them would
/// silently reset every user's saved width.
///
/// `setWidth` only mutates in-memory state (drives the live drag); the width is
/// flushed to disk once via `commit()` when the drag ends, so a gesture doesn't
/// hammer `UserDefaults` every frame.
@MainActor
final class ContextColumnWidth: ObservableObject {
    static let minWidth: CGFloat = 240
    static let defaultWidth: CGFloat = 320
    /// The centre column must keep at least this much room, so the context
    /// column can't be dragged wide enough to crush it. Reserved *on top of*
    /// the sidebar — see `clampedWidth`.
    static let minDetailWidth: CGFloat = 368
    /// Width of the resize handle's grab strip, overlaid on the column's leading
    /// edge (it takes no layout space, so it isn't reserved in the clamp).
    static let handleWidth: CGFloat = 11

    private static let globalKey = "chat.dock.width"
    private static let overridesKey = "chat.dock.widthOverrides"
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    @Published private var global: CGFloat
    @Published private var overrides: [String: CGFloat]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.globalKey)
        global = stored > 0 ? stored : Self.defaultWidth
        if let data = defaults.data(forKey: Self.overridesKey),
           let dict = try? Self.decoder.decode([String: CGFloat].self, from: data) {
            overrides = dict
        } else {
            overrides = [:]
        }
    }

    /// The width for a session (or the global default for the cross-session
    /// chat / an un-resized session), clamped to what the window can show.
    func width(for id: UUID?, totalWidth: CGFloat) -> CGFloat {
        let raw = id.flatMap { overrides[$0.uuidString] } ?? global
        return clamp(raw, totalWidth: totalWidth)
    }

    /// Live update while dragging — updates the global (so other chats follow)
    /// and, for a specific session, its override. In-memory only; call
    /// `commit()` when the drag ends to persist.
    func setWidth(_ raw: CGFloat, for id: UUID?, totalWidth: CGFloat) {
        let w = clamp(raw, totalWidth: totalWidth)
        global = w
        if let id { overrides[id.uuidString] = w }
    }

    /// Flush the current width to disk — called once when a drag ends.
    func commit() {
        persist()
    }

    /// Drop a session's override so it reverts to the global width.
    func resetWidth(for id: UUID?) {
        guard let id, overrides[id.uuidString] != nil else { return }
        overrides[id.uuidString] = nil
        persist()
    }

    /// Drop overrides for sessions that no longer exist so the dict stays
    /// bounded. No-op when `ids` is empty (e.g. list not loaded yet) so a cold
    /// cache can't wipe every override.
    func prune(keeping ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let live = Set(ids.map(\.uuidString))
        let kept = overrides.filter { live.contains($0.key) }
        guard kept.count != overrides.count else { return }
        overrides = kept
        persist()
    }

    private func clamp(_ w: CGFloat, totalWidth: CGFloat) -> CGFloat {
        Self.clampedWidth(w, totalWidth: totalWidth)
    }

    /// Pure clamp so the live drag preview (a local `@State`, not yet committed)
    /// uses the same bounds. When the window is narrow the upper bound can fall
    /// below minWidth; keep the dock usable by clamping the bound to minWidth.
    static func clampedWidth(_ w: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let upper = max(minWidth, totalWidth - HomeSidebar.width - minDetailWidth)
        return min(max(w, minWidth), upper)
    }

    private func persist() {
        defaults.set(global, forKey: Self.globalKey)
        if let data = try? Self.encoder.encode(overrides) {
            defaults.set(data, forKey: Self.overridesKey)
        }
    }
}
