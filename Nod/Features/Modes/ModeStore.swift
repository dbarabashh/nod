import Combine
import Foundation

/// Holds the user's meeting modes and the active selection — the single source
/// of truth for meeting framing. UI-prototype scope: modes are persisted locally
/// (Codable → `UserDefaults`), not synced anywhere. `MeetingSession` reads
/// `selected` at generation time via `MeetingFraming`, so there's no global
/// side channel to keep in sync.
@MainActor
final class ModeStore: ObservableObject {
    @Published var modes: [MeetingMode]
    @Published private(set) var selectedID: UUID

    private let defaults: UserDefaults
    private static let modesKey = "modes.v3"
    private static let selectedKey = "modes.selectedID"
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Coalesces the (expensive) modes-array JSON write so a burst of edits —
    /// e.g. typing into the Focus field — persists once, not per keystroke.
    private var modesWriteWork: DispatchWorkItem?
    private let modesWriteDelay: TimeInterval = 0.4

    /// Modes persisted before the Nucleo icon migration still hold raw SF
    /// Symbol names, which no longer resolve to any asset. Maps the exact
    /// names the shipped presets used; anything else (an icon a user picked
    /// from the old SF Symbol-based picker) falls back to a generic glyph.
    private static let legacyIconMap: [String: String] = [
        "circle.grid.2x2": "nc-grid-2",
        "person.crop.rectangle.stack": "nc-side-profile",
        "chart.line.uptrend.xyaxis": "nc-window-chart-line",
        "bubble.left.and.bubble.right": "nc-msgs",
        "checklist": "nc-tasks-2",
        "star": "nc-star"
    ]

    private static func migratingLegacyIcons(_ modes: [MeetingMode]) -> [MeetingMode] {
        guard modes.contains(where: { !$0.icon.hasPrefix("nc-") }) else { return modes }
        return modes.map { mode in
            guard !mode.icon.hasPrefix("nc-") else { return mode }
            var mode = mode
            mode.icon = legacyIconMap[mode.icon] ?? "nc-star"
            return mode
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = Self.loadModes(from: defaults)
        let hadPersisted = (loaded?.isEmpty == false)
        var modes = hadPersisted ? (loaded ?? []) : MeetingMode.presets
        let migratedModes = Self.migratingLegacyIcons(modes)
        let iconsMigrated = migratedModes != modes
        modes = migratedModes

        // First run of the modes feature: adopt whatever recap layout the user
        // had set through the now-removed standalone "Summary style" picker, so
        // the upgrade doesn't silently reset it. Match an existing preset; if it
        // matches none, keep it as a one-off custom mode.
        var migratedSelection: UUID?
        if !hadPersisted {
            if let summary = defaults.string(forKey: SummaryTemplate.defaultsKey).flatMap(SummaryTemplate.init) {
                if let match = modes.first(where: { $0.summary == summary }) {
                    migratedSelection = match.id
                } else {
                    let custom = MeetingMode(name: "Custom", icon: "nc-star", summary: summary)
                    modes.append(custom)
                    migratedSelection = custom.id
                }
            }
        }
        self.modes = modes

        let stored = defaults.string(forKey: Self.selectedKey).flatMap(UUID.init(uuidString:))
        let validStored = stored.flatMap { id in modes.contains { $0.id == id } ? id : nil }
        selectedID = migratedSelection ?? validStored ?? modes.first?.id ?? MeetingMode.fallback.id

        // Persist the seeded/migrated state once so the migration doesn't re-run.
        if !hadPersisted {
            writeModes()
            writeSelection()
        } else if iconsMigrated {
            writeModes()
        }
    }

    /// The active mode, with a non-optional fallback so callers never unwrap.
    var selected: MeetingMode {
        modes.first { $0.id == selectedID } ?? modes.first ?? .fallback
    }

    func select(_ id: UUID) {
        guard let mode = modes.first(where: { $0.id == id }) else { return }
        selectedID = id
        writeSelection()
        analytics?.record(.modeChanged, properties: .init(detail: Self.detail(of: mode)))
    }

    /// Counts a change of framing. Set by the composition root.
    var analytics: ProductAnalytics?

    /// A preset by its own name; anything a person made is `custom`, because
    /// its name is theirs and not a number.
    nonisolated static func detail(of mode: MeetingMode) -> ProductAnalytics.Detail {
        switch mode.name {
        case "General": .general
        case "Interview": .interview
        case "Sales call": .salesCall
        case "1:1": .oneOnOne
        case "Standup": .standup
        default: .custom
        }
    }

    /// Points a new user at the mode their role usually needs, so the first
    /// recap is already framed before they've opened Settings.
    ///
    /// Only while the selection is untouched: onboarding can run again on a
    /// reinstall or a second Mac, and answering "Manager" a second time must
    /// not overwrite the mode someone deliberately chose in between.
    func selectPreset(for role: WorkRole) {
        guard selectedID == modes.first?.id,
              let name = role.presetModeName,
              let match = modes.first(where: { $0.name == name })
        else { return }
        select(match.id)
    }

    @discardableResult
    func addMode() -> UUID {
        let mode = MeetingMode(name: "New mode", icon: "nc-star", summary: .auto)
        modes.append(mode)
        // Make the new mode active so authoring it and using it are the same act —
        // otherwise a freshly created mode is edited but silently inert.
        selectedID = mode.id
        flushModesWrite()
        writeSelection()
        return mode.id
    }

    func update(_ mode: MeetingMode) {
        guard let index = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        modes[index] = mode
        scheduleModesWrite()
    }

    func delete(_ id: UUID) {
        modes.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = modes.first?.id ?? MeetingMode.fallback.id
            writeSelection()
        }
        flushModesWrite()
    }

    private func writeModes() {
        if let data = try? Self.encoder.encode(modes) {
            defaults.set(data, forKey: Self.modesKey)
        }
    }

    private func writeSelection() {
        defaults.set(selectedID.uuidString, forKey: Self.selectedKey)
    }

    /// Debounced modes write for high-frequency edits (text typing).
    private func scheduleModesWrite() {
        modesWriteWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.modesWriteWork = nil
            self?.writeModes()
        }
        modesWriteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + modesWriteDelay, execute: work)
    }

    /// Immediate modes write for discrete actions (add/delete) — also cancels any
    /// pending debounced write so the latest in-memory state wins.
    private func flushModesWrite() {
        modesWriteWork?.cancel()
        modesWriteWork = nil
        writeModes()
    }

    private static func loadModes(from defaults: UserDefaults) -> [MeetingMode]? {
        guard let data = defaults.data(forKey: modesKey) else { return nil }
        return try? decoder.decode([MeetingMode].self, from: data)
    }
}
