import SwiftUI

/// The sidebar's ambient-context row: a status light, the feature's name, what
/// state it is in — and the menu of commands behind it.
///
/// A menu rather than a toggle, because the row's one job used to be
/// asymmetric: it switched capture off in a click and sent you to Settings to
/// switch it back on. A kill switch you can't undo where you pulled it is a
/// trap, and the states in between — pause it for this call, delete the last ten
/// minutes — had nowhere to live at all.
///
/// A *system* menu: these are one-shot commands, and `Menu` brings the hover,
/// keyboard navigation, dismissal and accessibility semantics that a hand-drawn
/// panel only approximates.
///
/// Settings › Privacy keeps the durable switch and the full disclosure; this is
/// the same feature's *right now*.
struct AmbientContextSidebarRow: View {
    @EnvironmentObject private var screenContext: ScreenContextService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pending: AmbientConfirmation?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Menu {
                menuItems
            } label: {
                row
            }
            .plainMenuChrome()
            .help(help)

            // The delete it reports happened server-side, so nothing on screen
            // visibly changes — without a word here the command looks inert.
            if let outcome = screenContext.lastDeletion {
                Text(Self.deletionMessage(outcome))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
                    .transition(.opacity)
            }
        }
        .animation(.standard(reduceMotion: reduceMotion), value: screenContext.lastDeletion)
        .confirmationDialog(
            Self.confirmationTitle(pending),
            isPresented: .isPresented(by: $pending),
            titleVisibility: .visible
        ) {
            confirmationActions
        } message: {
            Text(Self.confirmationMessage(pending, retentionDays: screenContext.retentionDays))
        }
    }

    // MARK: - Menu

    @ViewBuilder
    private var menuItems: some View {
        // Off the plan, the switch is the wrong control to offer: it would flip,
        // persist, and capture nothing, because RLS refuses the writes. So the
        // menu collapses to the one action that changes the answer, plus the
        // deletion commands — those keep working, since existing captures stay
        // readable and erasable.
        if case .notEntitled = screenContext.activityState {
            Text("Ambient context is part of Pro")
            Button("See Plans…") {
                NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
            }
        } else {
            // A checkmark item, so the state and the switch are the same control. A
            // separate "Turn off" at the bottom would be a second command for an
            // operation this already performs.
            Toggle("Ambient Context", isOn: enabledBinding)

            if case .needsAccessibility = screenContext.activityState {
                Button("Grant Accessibility Access…") { AccessibilityAccess.openSystemSettings() }
            }
        }

        // Keyed on the state, not on the raw switch: pausing a feature that is
        // already reading nothing is an offer with no meaning behind it.
        switch screenContext.activityState {
        case .on:
            Divider()
            Menu("Pause") {
                ForEach(AmbientPauseChoice.allCases) { choice in
                    Button(choice.rawValue) { screenContext.pause(for: choice.duration(from: Date())) }
                }
            }
        case .paused:
            Divider()
            Button("Resume Now") { screenContext.resume() }
        case .off, .notEntitled, .needsAccessibility:
            EmptyView()
        }

        Divider()

        Menu("Delete Recent Context") {
            ForEach(AmbientDeleteChoice.allCases) { choice in
                Button(choice.rawValue) { pending = .delete(choice) }
            }
        }

        Button("Excluded Apps and Websites…") {
            NotificationCenter.default.post(name: .nodOpenPrivacySettings, object: nil)
        }
    }

    @ViewBuilder
    private var confirmationActions: some View {
        switch pending {
        case .enable:
            Button("Turn On") { screenContext.setAmbientEnabled(true) }
            Button("Cancel", role: .cancel) {}
        case let .delete(choice):
            Button("Delete", role: .destructive) {
                Task { await screenContext.deleteObservations(since: choice.cutoff(from: Date())) }
            }
            Button("Cancel", role: .cancel) {}
        case nil:
            EmptyView()
        }
    }

    /// Switching capture *on* goes through a dialog; switching it off does not.
    /// Consent is the legal basis for ambient capture (`privacy.md` § 3.10(b)),
    /// so the disclosure has to be in front of the user at the moment they
    /// agree — and a menu item cannot carry a paragraph. Switching off needs no
    /// such ceremony: stopping is always allowed to be one click.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { screenContext.isAmbientEnabled },
            set: { wantsOn in
                if wantsOn {
                    pending = .enable
                } else {
                    screenContext.setAmbientEnabled(false)
                }
            }
        )
    }

    // MARK: - Row

    private var row: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(indicatorTint)
                .frame(width: 7, height: 7)
                // The same 16pt icon column the navigation rows use, so the
                // light sits under their glyphs instead of floating in the gap.
                .frame(width: 16)
            // The same name the setting carries in Settings › Privacy and in the
            // privacy policy — one feature, one word for it.
            Text("Ambient context")
                .font(.system(size: 12.5))
                .lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: 6)
            status
        }
        .foregroundStyle(Theme.Palette.ink.opacity(0.72))
        .padding(.horizontal, 9)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .contentShape(Rectangle())
    }

    /// Only the paused state needs a clock, so only it pays for one. Per minute,
    /// because that is the finest granularity `label` reports — and `.everyMinute`
    /// is phase-aligned to the minute boundary, so the text changes when the
    /// number does rather than up to a tick later.
    @ViewBuilder
    private var status: some View {
        if screenContext.isPaused {
            TimelineView(.everyMinute) { context in
                statusText(now: context.date)
            }
        } else {
            statusText(now: Date())
        }
    }

    private func statusText(now: Date) -> some View {
        Text(screenContext.activityState.label(now: now))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.Palette.muted)
            .lineLimit(1)
    }

    /// Traffic lights, and they mean what traffic lights mean: green is reading,
    /// red is not, amber is switched on but held. Red rather than grey for `off`
    /// — grey reads as "disabled control", and the one thing this dot has to
    /// answer at a glance is whether Nod is looking.
    private var indicatorTint: Color {
        switch screenContext.activityState {
        case .on: Theme.Palette.success
        case .off: Theme.Palette.danger
        // Grey, not red: red answers "is Nod looking at me", and the answer here
        // is not "no, it stopped" but "this isn't yours to switch on".
        case .notEntitled: Theme.Palette.muted
        case .paused, .needsAccessibility: Theme.Palette.warning
        }
    }

    private var help: String {
        switch screenContext.activityState {
        case .off: "Ambient context is off — Nod reads nothing from your screen"
        case .notEntitled: "Ambient context is part of Pro"
        case .needsAccessibility: "Ambient context needs Accessibility access"
        case .paused: "Ambient context is paused — nothing is being read"
        case .on: "Ambient context is on — Nod reads the window you're working in"
        }
    }

    // MARK: - Copy

    /// Says what happened in the user's terms, including when nothing did — a
    /// silent "0 deleted" reads as a broken button, and a failure the user never
    /// hears about reads as a successful one. Names the app on a per-app delete
    /// so this reads correctly wherever it surfaces — the sidebar's time-window
    /// menu and Settings' per-app menu share one `lastDeletion`, and either can
    /// be on screen when the other fires.
    static func deletionMessage(_ outcome: ScreenContextService.DeletionOutcome) -> String {
        switch outcome {
        case .failed: "Couldn't delete — check your connection."
        case let .deleted(count, appName) where count == 0:
            appName.map { "Nothing captured from \($0)." } ?? "Nothing captured in that window."
        case let .deleted(1, appName):
            appName.map { "Deleted 1 capture from \($0)." } ?? "Deleted 1 capture."
        case let .deleted(count, appName):
            appName.map { "Deleted \(count) captures from \($0)." } ?? "Deleted \(count) captures."
        }
    }

    static func confirmationTitle(_ pending: AmbientConfirmation?) -> String {
        switch pending {
        case .enable: "Turn on ambient context?"
        case .delete(.everything): "Delete all captured context?"
        case let .delete(choice): "Delete context from the \(choice.rawValue.lowercased())?"
        case nil: ""
        }
    }

    /// The retention figure is read from the setting, not written into the
    /// sentence: it is user-selectable (7/14/30), and a disclosure that always
    /// said "14 days" told everyone else something untrue at the exact moment
    /// they were consenting to it.
    static func confirmationMessage(_ pending: AmbientConfirmation?, retentionDays: Int) -> String {
        switch pending {
        case .enable:
            "Nod will read the text of the window you're working in, so you can ask about what you "
                + "were doing — not just what was said. Excluded apps and sites are never read, no "
                + "images are ever saved, and captures are deleted after \(retentionDays) days. You "
                + "can pause or switch this off at any time."
        case .delete:
            "Deleted context can't be recovered. Your sessions and transcripts are not affected."
        case nil:
            ""
        }
    }
}

/// The two things that get a dialog before they happen: irreversible deletion,
/// and the one switch that widens what Nod reads.
enum AmbientConfirmation: Equatable {
    case enable
    case delete(AmbientDeleteChoice)
}

/// How long a pause lasts. Three, because the question behind it is only ever
/// "this call", "this afternoon", or "the rest of today".
enum AmbientPauseChoice: String, CaseIterable, Identifiable {
    case fifteenMinutes = "For 15 Minutes"
    case hour = "For 1 Hour"
    // Named for where it ends, not for the day it's in: a pause chosen at 11pm
    // that says "Today" reads as a minute long.
    case untilTomorrow = "Until Tomorrow"

    var id: String {
        rawValue
    }

    /// `untilTomorrow` is measured to the end of the day rather than a fixed
    /// span, so the same words mean the same thing at 9am and at 5pm.
    ///
    /// Via `dateInterval` rather than +86400: a DST day is 23 or 25 hours long,
    /// and adding a fixed day to it either resumes capture an hour early or
    /// holds it an hour past midnight.
    func duration(from now: Date, calendar: Calendar = .current) -> TimeInterval {
        switch self {
        case .fifteenMinutes: 15 * 60
        case .hour: 60 * 60
        case .untilTomorrow: Self.startOfNextDay(after: now, calendar: calendar).timeIntervalSince(now)
        }
    }

    static func startOfNextDay(after now: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .day, for: now)?.end
            ?? calendar.startOfDay(for: now).addingTimeInterval(24 * 60 * 60)
    }
}

/// Delete windows. Recent-first: the reason someone opens this is almost always
/// "that last thing shouldn't have been read".
enum AmbientDeleteChoice: String, CaseIterable, Identifiable {
    case fiveMinutes = "Last 5 Minutes"
    case fifteenMinutes = "Last 15 Minutes"
    case hour = "Last Hour"
    case everything = "Everything"

    var id: String {
        rawValue
    }

    /// Nil means no lower bound — every observation goes.
    func cutoff(from now: Date) -> Date? {
        switch self {
        case .fiveMinutes: now.addingTimeInterval(-5 * 60)
        case .fifteenMinutes: now.addingTimeInterval(-15 * 60)
        case .hour: now.addingTimeInterval(-60 * 60)
        case .everything: nil
        }
    }
}

#Preview {
    let defaults = UserDefaults(suiteName: "preview.ambient.row") ?? .standard
    let exclusions = ScreenExclusions(defaults: defaults, seedDefaults: false)
    return AmbientContextSidebarRow()
        .environmentObject(ScreenContextService(supabase: nil, exclusions: exclusions))
        .padding(10)
        .frame(width: HomeSidebar.width)
        .background(Theme.Palette.bg)
}
