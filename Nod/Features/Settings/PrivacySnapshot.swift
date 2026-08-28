import SwiftUI

/// The four questions somebody actually has, answered before any control is
/// offered.
///
/// A page that opens on switches asks the reader to work out the guarantee from
/// the settings. This states it, and every line is checked against the code
/// rather than against what we would like to be true — see the WHY on each row
/// for what it is traceable to. Changing any of those code paths means changing
/// the line here and the matching section of `docs/policies/privacy.md`.
struct PrivacySnapshot: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("What Nod does with your work")
            SettingsCard {
                row(
                    icon: "nc-mic",
                    title: "Recordings become text",
                    // `LLMProxyClient.transcribe` posts audio to the proxy, which
                    // forwards it to a speech-to-text provider; only the returned
                    // text is written. Nothing writes audio to disk outside a
                    // DEBUG-only dump behind its own flag (`DebugAudioDump`).
                    detail: "Audio is sent for transcription and is never stored — not on our servers, not on your Mac. What's kept is the text."
                )
                SettingsRowDivider()
                row(
                    icon: "nc-window-pointer",
                    title: "Your screen stays yours",
                    // Ambient capture is file-gated off by default
                    // (`ScreenContextService`). The two reads that run regardless
                    // are the conferencing-window title sweep in `MeetingDetector`
                    // and the participant list in `MeetingRoster`; neither is
                    // persisted. Where the accessibility tree is too thin, the
                    // window is OCR'd in memory and only the text is stored — see
                    // `ScreenTextRecognizer`.
                    detail: "Nothing on screen is stored unless you switch ambient context on. To notice a call, Nod reads conferencing window titles and the participant list while recording — "
                        + "neither is saved, and no image of your screen is ever kept."
                )
                SettingsRowDivider()
                row(
                    icon: "nc-lock",
                    title: "Only you can read it",
                    // Base RLS on `meetings` / `meeting_transcripts` is
                    // `auth.uid() = user_id`; every widening policy needs a share
                    // you created. The admin overlay is gated on
                    // `org_policies.admin_content_access`, which defaults false
                    // and has no UPDATE policy and no RPC — nothing in any client
                    // can turn it on. Delete that clause the day that ships.
                    //
                    // The team sentence is not decoration: administrators write
                    // `team_members`, and `can_read_meeting_via_grant` answers
                    // yes on a row in it, so an administrator can reach a team
                    // share by putting an account in the team. Saying only the
                    // first half here would be a claim the code does not keep.
                    detail: "Sessions are yours until you share one, and sharing is per session. Administrators can't open a session you kept to yourself — Nod ships no way to turn that on. What you share with a team, though, is readable by whoever is in that team, and administrators decide who that is."
                )
                SettingsRowDivider()
                row(
                    icon: "nc-refresh-2",
                    title: "It leaves when you say",
                    // `purge-trashed-meetings` (daily 03:00 UTC, 30 days) and
                    // `purge-expired-screen-observations` (daily 04:17 UTC, from
                    // the row's own `expires_at`) are pg_cron jobs, so neither
                    // waits for the app to open.
                    detail: "Sessions stay until you delete them, then sit in the trash for 30 days. Screen context deletes itself on the server on your schedule, even if you never open Nod again."
                )
                SettingsRowDivider()
                policyRow
            }
        }
    }

    private func row(icon: String, title: String, detail: String) -> some View {
        SettingsRow(icon: icon, title: title, subtitle: detail) {
            EmptyView()
        }
    }

    /// The snapshot is a summary and says so. Everything it compresses —
    /// subprocessors, lawful basis, the rest — lives in the published policy.
    private var policyRow: some View {
        Link(destination: EmailConsentLinks.privacy) {
            HStack(spacing: 8) {
                Text("Read the full privacy policy")
                    .font(.system(size: 12))
                Image("nc-arrow-up-right")
                    .icon(10)
            }
            .foregroundStyle(Theme.Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
    }
}

#Preview {
    PrivacySnapshot()
        .padding()
        .frame(width: 520)
        .background(WindowBackdrop())
}
