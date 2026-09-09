import SwiftUI

/// The asks onboarding left for later, each raised on Today where it is first
/// worth granting: the audio of a call before the first call, the screen once
/// there is something to ask about it, and who the person is once Nod has
/// done something for them. Each goes away on its own once answered, and a
/// "Not now" is remembered per account so the card does not nag.
enum TodayNudge: String, CaseIterable {
    case systemAudio
    case ambient
    case profile

    private static let prefix = "today-nudge"

    static func isDismissed(_ nudge: TodayNudge, for userID: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: key(nudge, userID))
    }

    static func dismiss(_ nudge: TodayNudge, for userID: UUID) {
        UserDefaults.standard.set(true, forKey: key(nudge, userID))
    }

    private static func key(_ nudge: TodayNudge, _ userID: UUID) -> String {
        "\(prefix).\(nudge.rawValue).\(userID.uuidString)"
    }

    #if DEBUG || NOD_SANDBOX
        /// Every account's dismissals, for the first-run reset in Settings.
        static func resetPersistedDismissals() {
            let defaults = UserDefaults.standard
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
                defaults.removeObject(forKey: key)
            }
        }
    #endif
}

/// Screen Recording, asked before the first call rather than in onboarding:
/// the grant needs a relaunch, and a relaunch with a reason in front of it
/// is one people do.
struct TodaySystemAudioCard: View {
    @ObservedObject var permissions: PermissionManager
    let onDismiss: () -> Void

    @State private var isRequesting = false

    var body: some View {
        TodayNudgeCard(
            icon: "nc-volume-up",
            title: "Hear the other side of your calls",
            text: "macOS calls it Screen Recording. It's the audio your Mac plays — never your screen. "
                + "macOS applies it after Nod restarts.",
            footnote: footnote
        ) {
            switch permissions.screenRecording {
            case .authorized:
                EmptyView()
            case .denied where permissions.requestedScreenRecordingThisSession:
                GlassPillButton("Quit & Relaunch Nod", size: .compact, action: permissions.relaunch)
            case .denied:
                GlassPillButton("Open Settings", size: .compact, action: permissions.openScreenRecordingSettings)
            case .notDetermined:
                GlassPillButton("Allow", size: .compact, isLoading: isRequesting, action: allow)
            }
            SecondaryPillButton("Not now", action: onDismiss)
        }
    }

    private var footnote: String? {
        guard permissions.requestedScreenRecordingThisSession, permissions.screenRecording != .authorized else { return nil }
        return permissions.relaunchMessage
    }

    private func allow() {
        guard !isRequesting else { return }
        isRequesting = true
        Task { @MainActor in
            _ = await permissions.requestScreenRecording()
            isRequesting = false
        }
    }
}

/// The ambient ask. Every line here is one `privacy.md` § 3.10(b) makes, and
/// the switch it flips is the same one Settings and the sidebar control flip:
/// off until this click, bounded, and the person's to pause or delete.
struct TodayAmbientCard: View {
    @ObservedObject var screenContext: ScreenContextService
    let onDismiss: () -> Void

    var body: some View {
        TodayNudgeCard(
            icon: "nc-stack-perspective",
            title: "Let me see what you're working on",
            text: "Text from the window in front of you, kept \(screenContext.retentionDays) days, never an image. "
                + "Then you can ask about your screen, and your commitments get the context they came from.",
            footnote: screenContext.needsAccessibility ? "Add Nod under Accessibility. I'll notice the moment it's on." : nil
        ) {
            if screenContext.needsAccessibility {
                GlassPillButton("Open System Settings", size: .compact, action: AccessibilityAccess.openSystemSettings)
            } else {
                GlassPillButton("Turn on", size: .compact) { screenContext.setAmbientEnabled(true) }
            }
            SecondaryPillButton("Not now", action: onDismiss)
        }
    }
}

/// Who this is, asked once Nod has been useful rather than before. The role
/// picks the starting mode; where they heard of Nod is for us; the line on
/// what to win at sharpens every recap.
struct TodayProfileCard: View {
    let onSave: (_ role: WorkRole?, _ heardFrom: AcquisitionSource?, _ preferences: String) -> Void
    let onDismiss: () -> Void

    @State private var role: WorkRole?
    @State private var heardFrom: AcquisitionSource?
    @State private var preferences: String

    init(
        initialRole: WorkRole?,
        initialHeardFrom: AcquisitionSource?,
        initialPreferences: String,
        onSave: @escaping (WorkRole?, AcquisitionSource?, String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onDismiss = onDismiss
        _role = State(initialValue: initialRole)
        _heardFrom = State(initialValue: initialHeardFrom)
        _preferences = State(initialValue: initialPreferences)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TodayNudgeHeader(
                icon: "nc-user",
                title: "Two questions, so every recap is sharper",
                text: "Optional. Your name and what to win at can be changed in Settings."
            )

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("What do you do?")
                Menu {
                    ForEach(WorkRole.allCases) { option in
                        Button {
                            role = option
                        } label: {
                            if option == role {
                                IconLabel(title: option.title, icon: "nc-check")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(role?.title ?? "Select…")
                            .textStyle(Theme.Typography.ui)
                            .foregroundStyle(role == nil ? Theme.Palette.muted : Theme.Palette.ink)
                        Image("nc-chevron-expand-y")
                            .icon(9)
                            .foregroundStyle(Theme.Palette.muted)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                            .fill(Theme.Palette.surfaceStrong)
                    )
                }
                .plainMenuChrome()
                .accessibilityLabel("What do you do?")
                if let name = role?.presetModeName {
                    Text("Starts you in \(name) mode unless you've already picked one.")
                        .textStyle(Theme.Typography.meta)
                        .foregroundStyle(Theme.Palette.muted)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("How'd you find Nod?")
                AcquisitionSourceChips(selected: $heardFrom)
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("What should Nod help you win at?")
                TextField(
                    "Track what people commit to me, surface risks early…",
                    text: $preferences,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .textStyle(Theme.Typography.ui)
                .lineLimit(1 ... 3)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .fill(Theme.Palette.surfaceStrong)
                )
            }

            HStack(spacing: 8) {
                GlassPillButton("Save", size: .compact) { onSave(role, heardFrom, preferences) }
                    .disabled(!hasAnswer)
                    .opacity(hasAnswer ? 1 : 0.5)
                SecondaryPillButton("Later", action: onDismiss)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }

    private var hasAnswer: Bool {
        role != nil || heardFrom != nil || !preferences.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One ask: an icon, a claim, what it is not, and the buttons.
private struct TodayNudgeCard<Actions: View>: View {
    let icon: String
    let title: String
    let text: String
    let footnote: String?
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TodayNudgeHeader(icon: icon, title: title, text: text, footnote: footnote)
            HStack(spacing: 8) {
                actions()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }
}

/// The top of every ask on Today: the mark, the claim, and what it is not.
private struct TodayNudgeHeader: View {
    let icon: String
    let title: String
    let text: String
    var footnote: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(icon)
                .icon(13)
                .foregroundStyle(Theme.Palette.brand)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .textStyle(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Palette.ink)
                Text(text)
                    .textStyle(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let footnote {
                    Text(footnote)
                        .textStyle(Theme.Typography.meta)
                        .foregroundStyle(Theme.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
