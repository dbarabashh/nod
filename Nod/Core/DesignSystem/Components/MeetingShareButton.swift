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

    var body: some View {
        if let orgID = organizations.activeOrgID, let membership = organizations.activeMembership {
            let teams = organizations.teams(in: orgID)
            let existing = grants.grants(forMeeting: meetingID)
            Menu {
                audiences(teams: teams, existing: existing, orgID: orgID, orgName: membership.organization.name)
            } label: {
                label(
                    title: title(for: existing, teams: teams, orgName: membership.organization.name),
                    isShared: !existing.isEmpty
                )
            }
            // Not `.borderlessButton`, which centres the title and drops
            // anything beside it — the glyph would vanish. See `plainMenuChrome`.
            // Disabled until the row is on the server: the recap card appears
            // the instant a recording stops, and `grant_meeting` refuses a
            // meeting it cannot find.
            .plainMenuChrome()
            .fixedSize()
            .disabled(!isReady)
            .opacity(isReady ? 1 : 0.4)
            .linkCursor()
        }
    }

    @ViewBuilder
    private func audiences(teams: [Team], existing: [MeetingGrant], orgID: UUID, orgName: String) -> some View {
        ForEach(teams) { team in
            if let grant = existing.first(where: { $0.teamID == team.id }) {
                Button("Stop sharing with \(team.name)") {
                    Task { await grants.unshare(grant) }
                }
            } else {
                Button("Share with \(team.name)") {
                    Task { await grants.share(meetingID, withTeam: team.id, org: nil) }
                }
            }
        }
        if let grant = existing.first(where: { $0.orgID != nil }) {
            Button("Stop sharing with \(orgName)") {
                Task { await grants.unshare(grant) }
            }
        } else {
            Button("Share with all of \(orgName)") {
                Task { await grants.share(meetingID, withTeam: nil, org: orgID) }
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
