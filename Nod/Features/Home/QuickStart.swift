import SwiftUI

/// What onboarding leaves behind: the setup that is still unfinished, and the
/// buttons that finish it.
///
/// Hides itself once every row is done — a checklist that stays after it is
/// complete stops being a checklist.
struct QuickStart: View {
    let hasSession: Bool

    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var calendar: CalendarService
    @EnvironmentObject private var integrations: IntegrationService
    let onStartCapture: () -> Void

    @State private var isAskingForCalendar = false

    private var hasCalendar: Bool {
        CalendarSourceState.isAnswered(calendar: calendar, integrations: integrations)
    }

    private var remaining: Int {
        [permissions.canCaptureBothSides, hasCalendar, hasSession].filter { !$0 }.count
    }

    var body: some View {
        if remaining > 0 {
            VStack(alignment: .leading, spacing: 0) {
                header
                row(
                    icon: "nc-mic",
                    title: "Let Nod hear what's said",
                    detail: "The microphone and your Mac's own audio — both sides of a conversation.",
                    isDone: permissions.canCaptureBothSides
                )
                divider
                row(
                    icon: "nc-calendar",
                    title: "Connect a calendar",
                    detail: "Names the session, and tells Nod who is in it — which is how the transcript gets names instead of \"Speaker 2\".",
                    isDone: hasCalendar,
                    action: { isAskingForCalendar = true }
                )
                divider
                row(
                    icon: "nc-sparkle-3",
                    title: "Capture your first session",
                    detail: "A meeting, a voice note, or anything playing through your Mac.",
                    isDone: hasSession,
                    action: onStartCapture
                )
            }
            .frame(maxWidth: 460)
            .surfaceCard()
            .sheet(isPresented: $isAskingForCalendar) {
                // The canonical two-source ask, rather than a jump to Settings:
                // that pane carries only the switch for this Mac's calendar, so
                // somebody who wanted the Google one was sent somewhere that
                // could not give it to them.
                CalendarPromptView(calendar: calendar, integrations: integrations) {
                    isAskingForCalendar = false
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Get set up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text("\(remaining) left")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.muted)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var divider: SettingsRowDivider {
        SettingsRowDivider(indent: 45)
    }

    private func row(
        icon: String,
        title: String,
        detail: String,
        isDone: Bool,
        action: (() -> Void)? = nil
    ) -> some View {
        SettingsRow(
            title: title,
            subtitle: detail,
            titleStyle: isDone ? .done : .standard,
            alignment: .top
        ) {
            Image(isDone ? "nc-circle-check" : icon)
                .icon(14)
                .foregroundStyle(isDone ? Theme.Palette.success : Theme.Palette.ink.opacity(0.7))
                .frame(width: 20)
                .padding(.top, 1)
        } trailing: {
            if !isDone, let action {
                Button(action: action) {
                    Text("Start")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .glassButtonSurface(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
        }
    }
}
