import AppKit
import SwiftUI

/// The one switch in Nod that widens what it reads beyond a recording, and the
/// state it is in right now.
///
/// The exhaustive app and site lists used to be this view. They are the answer
/// to "what *can* it see?", which is a question people ask once and check
/// rarely — put first, two hundred identical switches turned a page about
/// reassurance into a page about chores. They live behind a door now.
struct ScreenPrivacySection: View {
    @ObservedObject var exclusions: ScreenExclusions
    @ObservedObject var screenContext: ScreenContextService

    /// Seeded from the file-backed flag, not `@AppStorage`: the durable value
    /// lives in `ScreenContextDefaults`, and binding the switch to the old
    /// UserDefaults key would show off whenever that key was dropped on exit.
    /// Bound to the service's published switch, not a local mirror — the
    /// sidebar offers the same toggle, and two mirrors of one file flag drift.
    private var ambientEnabled: Bool {
        screenContext.isAmbientEnabled
    }

    /// Gates the rows that only make sense while capture can actually run — the
    /// Accessibility prompt in particular, since asking an unentitled account
    /// for a permission it cannot use is a dead end.
    ///
    /// Retention deliberately does NOT use this. The RLS gate leaves SELECT and
    /// DELETE open so a downgraded user can still manage what Nod already
    /// stored, and hiding the picker would leave those rows under a ceiling only
    /// we could change.
    private var ambientRunnable: Bool {
        screenContext.isEntitled && screenContext.isAmbientEnabled
    }

    @AppStorage(ScreenContextDefaults.retentionDaysKey) private var retentionDays = ScreenContextDefaults.defaultRetentionDays
    @State private var isReviewingExclusions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ambientContextCard
            exclusionsCard
        }
        .sheet(isPresented: $isReviewingExclusions) {
            ExclusionsSheet(exclusions: exclusions, screenContext: screenContext)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Screen")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text(
                "A recording captures what is said. Reading the window you're working in is a separate choice, and it is off until you make it."
            )
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// States the trade in the row itself rather than in a policy the user will
    /// not open, and says what is true right now — a switch alone leaves "so is
    /// it reading my screen or not" to be inferred.
    private var ambientContextCard: some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-sparkle-3",
                title: "Ambient context",
                subtitle: "Let Nod read the window you're working in, so you can ask about what you were doing — not just what was said."
            ) {
                // Off the plan the switch would flip, persist, and capture
                // nothing — RLS refuses the writes — so it is replaced by the
                // one control that changes the answer.
                if screenContext.isEntitled {
                    Toggle("", isOn: Binding(
                        get: { screenContext.isAmbientEnabled },
                        set: { screenContext.setAmbientEnabled($0) }
                    ))
                    .nodSwitch()
                    .labelsHidden()
                    .controlSize(.small)
                } else {
                    Button("Upgrade to Pro") {
                        NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
                    }
                }
            }

            SettingsRowDivider()
            stateRow

            if ambientRunnable, screenContext.needsAccessibility {
                SettingsRowDivider()
                SettingsRow(
                    icon: "nc-triangle-warning",
                    title: "Accessibility access needed",
                    subtitle: "macOS has to allow Nod to read window text before ambient context can run. "
                        + "Grant it in System Settings, then switch this back on."
                ) {
                    Button("Open Settings") { AccessibilityAccess.openSystemSettings() }
                }
            }

            if ambientEnabled {
                SettingsRowDivider()
                SettingsRow(
                    icon: "nc-refresh-2",
                    title: "Keep for",
                    subtitle: "Older context is deleted automatically, on the server, even if you never open Nod again."
                ) {
                    Picker("", selection: $retentionDays) {
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
            }
        }
    }

    /// Reads the service, not the switch. A pause leaves the switch on while
    /// nothing is captured, and the two used to disagree silently.
    private var stateRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isReading ? Theme.Palette.success : Theme.Palette.muted.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(stateDescription)
                .font(.system(size: 12))
                .foregroundStyle(isReading ? Theme.Palette.ink : Theme.Palette.muted)
            Spacer(minLength: 8)
            if case let .paused(until) = screenContext.activityState {
                Button("Resume now") { screenContext.resume() }
                    .font(.system(size: 12))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Palette.muted)
                    .accessibilityHint("Paused \(ScreenContextService.ActivityState.remaining(until: until))")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private var isReading: Bool {
        guard ambientRunnable, !screenContext.needsAccessibility else { return false }
        if case .paused = screenContext.activityState { return false }
        return true
    }

    private var stateDescription: String {
        if case let .paused(until) = screenContext.activityState {
            return "Paused \(ScreenContextService.ActivityState.remaining(until: until)) — nothing is being read"
        }
        guard ambientEnabled else { return "Off — Nod is not reading your screen" }
        guard screenContext.isEntitled else { return "Off — ambient context needs a Pro plan" }
        guard !screenContext.needsAccessibility else { return "Waiting on macOS permission — nothing is being read" }
        return "On — Nod reads the window you're working in, except what you excluded"
    }

    /// The whole list, one line. What people want from it at a glance is a
    /// count they can trust, not a scroll.
    private var exclusionsCard: some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-shield-check",
                title: "Never read",
                subtitle: exclusionsSummary
            ) {
                Button("Review") { isReviewingExclusions = true }
                    .font(.system(size: 12.5))
            }
        }
    }

    private var exclusionsSummary: String {
        let apps = exclusions.apps.count
        let sites = exclusions.websiteRuleCount
        let appPart = "\(apps) \(apps == 1 ? "app" : "apps")"
        let sitePart = "\(sites) \(sites == 1 ? "site rule" : "site rules")"
        return "\(appPart) and \(sitePart) are never read, whatever else is on. Passwords, banking and health sites are excluded out of the box."
    }
}

#Preview {
    let defaults = UserDefaults(suiteName: "preview") ?? .standard
    let exclusions = ScreenExclusions(defaults: defaults)
    return ScreenPrivacySection(
        exclusions: exclusions,
        screenContext: ScreenContextService(supabase: nil, exclusions: exclusions)
    )
    .padding()
    .frame(width: 460)
}
