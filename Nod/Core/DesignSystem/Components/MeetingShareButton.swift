import SwiftUI

/// Hands one meeting to a team, or to the whole organization.
///
/// Mounted where a meeting is finished rather than where it is filed: the moment
/// somebody decides colleagues should see a call is the moment it ends, and by
/// then they have not put it in a folder — so `LabelStore`'s folder sharing,
/// which is the right tool for a body of work, cannot answer this.
///
/// The audience is never a person. Somebody who listened in gets the recording
/// because they are on the team the host chose, not because they were in the
/// room — a grant written in the second vocabulary would quietly change meaning
/// every time the roster did.
///
/// Absent entirely for an account in no organization: there is nobody to share
/// with, and a control that opens onto an empty list is a question with no
/// answer.
struct MeetingShareButton: View {
    let meetingID: UUID
    /// False until the meeting exists on the server. See `MeetingStore.isPersisted`.
    var isReady = true

    @EnvironmentObject private var grants: MeetingGrantStore
    @EnvironmentObject private var organizations: OrganizationService
    @State private var isPicking = false

    var body: some View {
        if let orgID = organizations.activeOrgID, let membership = organizations.activeMembership {
            let teams = organizations.teams(in: orgID)
            let existing = grants.grants(forMeeting: meetingID)
            Button { isPicking = true } label: {
                label(
                    title: title(for: existing, teams: teams, orgName: membership.organization.name),
                    isShared: !existing.isEmpty
                )
            }
            // Disabled until the row is on the server: the recap card appears
            // the instant a recording stops, and `grant_meeting` refuses a
            // meeting it cannot find.
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(!isReady)
            .opacity(isReady ? 1 : 0.4)
            .linkCursor()
            .dismissWhenMoved($isPicking)
            .popover(isPresented: $isPicking, arrowEdge: .bottom) {
                MeetingSharePicker(
                    meetingID: meetingID,
                    teams: teams,
                    existing: existing,
                    orgID: orgID,
                    orgName: membership.organization.name
                )
            }
        }
    }

    /// Colour carries the shared state, but never alone — the words change with
    /// it, so the reading survives `differentiateWithoutColor` and a screen
    /// reader alike.
    private func label(title: String, isShared: Bool) -> some View {
        HStack(spacing: 5) {
            Image("nc-users")
                .icon(11)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(isShared ? Theme.Palette.brand : Theme.Palette.muted)
        .contentShape(Rectangle())
    }

    /// Says who has it, not just that sharing exists — the host's actual
    /// question when they look back at a meeting is "did I send this, and to
    /// whom", and a control reading "Share" answers neither.
    private func title(for existing: [MeetingGrant], teams: [Team], orgName: String) -> String {
        guard let only = existing.first else { return "Share" }
        guard existing.count == 1 else { return "Shared with \(existing.count) groups" }
        if only.orgID != nil {
            return "Shared with \(orgName)"
        }
        return teams.first { $0.id == only.teamID }.map { "Shared with \($0.name)" } ?? "Shared"
    }
}

/// Who a meeting is handed to, as a list you tick.
///
/// The same surface the project and calendar pickers open — one card, one row
/// per choice, a check on what is already true. It was a menu of verbs ("Stop
/// sharing with Founders", "Share with all of Nod"), which is the same
/// information written as instructions: a person had to read four sentences to
/// work out that two of them were on. A list of audiences with two ticks says
/// it once.
///
/// The audience is a team, never a person — a grant written per-person changes
/// meaning every time the roster does.
struct MeetingSharePicker: View {
    let meetingID: UUID
    let teams: [Team]
    let existing: [MeetingGrant]
    let orgID: UUID
    let orgName: String

    @EnvironmentObject private var grants: MeetingGrantStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering: UUID?

    var body: some View {
        VStack(spacing: 0) {
            SectionLabel("Who can see this")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.x3)
                .padding(.top, Theme.Space.x3)
                .padding(.bottom, Theme.Space.x2)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(teams) { team in
                        row(
                            id: team.id,
                            icon: "nc-users",
                            title: team.name,
                            grant: existing.first { $0.teamID == team.id },
                            share: { await grants.share(meetingID, withTeam: team.id, org: nil) }
                        )
                    }
                    row(
                        id: orgID,
                        icon: "nc-users",
                        title: "Everyone at \(orgName)",
                        grant: existing.first { $0.orgID != nil },
                        share: { await grants.share(meetingID, withTeam: nil, org: orgID) }
                    )
                }
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 264)
    }

    private func row(
        id: UUID,
        icon: String,
        title: String,
        grant: MeetingGrant?,
        share: @escaping () async -> Void
    ) -> some View {
        HStack(spacing: Theme.Space.x2) {
            Image(icon)
                .icon(Theme.Control.iconMicro)
                .foregroundStyle(Theme.Palette.muted)
            Text(title)
                .textStyle(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            if grant != nil {
                Image("nc-check")
                    .icon(11)
                    .foregroundStyle(Theme.Palette.violet)
            }
        }
        .padding(.horizontal, Theme.Space.x3)
        .padding(.vertical, Theme.Space.x2)
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                if let grant {
                    await grants.unshare(grant)
                } else {
                    await share()
                }
            }
        }
        .onHover { if $0 { hovering = id } else if hovering == id { hovering = nil } }
        .animation(.hoverReveal(reduceMotion: reduceMotion), value: hovering)
    }
}

#if DEBUG
    private struct MeetingSharePreview: View {
        let grants: MeetingGrantStore
        let meetingID: UUID

        var body: some View {
            MeetingShareButton(meetingID: meetingID)
                .environmentObject(grants)
                .environmentObject(OrganizationService.preview(
                    memberships: [OrgMembership(
                        organization: Organization(id: Self.org, name: "Acme", slug: "acme"),
                        role: .owner
                    )],
                    activeOrgID: Self.org,
                    teams: [Team(id: Self.team, orgID: Self.org, name: "Design")]
                ))
                .padding()
                .background(WindowBackdrop())
        }

        static let org = UUID()
        static let team = UUID()
    }

    #Preview("Unshared") {
        let meeting = UUID()
        return MeetingSharePreview(grants: .preview(), meetingID: meeting)
    }

    #Preview("Shared with a team") {
        let meeting = UUID()
        return MeetingSharePreview(
            grants: .preview(grants: [MeetingGrant(
                id: UUID(),
                meetingID: meeting,
                teamID: MeetingSharePreview.team,
                orgID: nil
            )]),
            meetingID: meeting
        )
    }
#endif
