import SwiftUI

/// One team, expandable into its roster.
///
/// The roster loads when the row is opened rather than with the pane: an
/// organization with a dozen teams would otherwise fetch a dozen lists nobody
/// asked to see, and each one costs a round trip that reads addresses.
struct TeamRow: View {
    let team: Team
    let canAdminister: Bool
    let members: [TeamMember]?
    let candidates: [OrgMember]
    let load: () async -> Void
    let rename: (String) -> Void
    let delete: () -> Void
    let add: (OrgMember) -> Void
    let remove: (TeamMember) -> Void
    /// Non-nil when the viewer is in this team and may walk out of it.
    var leave: (() -> Void)?

    @State private var isExpanded = false
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var isConfirmingDelete = false

    private var unassigned: [OrgMember] {
        let present = Set(members?.map(\.userID) ?? [])
        return candidates.filter { !present.contains($0.userID) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                roster
            }
        }
        .confirmationDialog(
            "Delete the \(team.name) team?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete team", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("People stay in the organization and keep everything they recorded. Integrations pointed at this team go back to unscoped.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(isExpanded ? "nc-chevron-down" : "nc-chevron-right")
                        .icon(9)
                        .foregroundStyle(Theme.Palette.muted)
                        .accessibilityHidden(true)
                    if isRenaming {
                        TextField("Team name", text: $draftName, onCommit: commitRename)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5))
                            .frame(maxWidth: 220)
                    } else {
                        Text(team.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.Palette.ink)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(team.name), \(isExpanded ? "expanded" : "collapsed")")

            Spacer(minLength: 8)

            if let members {
                Text("\(members.count)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
            }
            if canAdminister {
                Menu {
                    Button("Rename…") { startRename() }
                    if let leave {
                        Button("Leave team", action: leave)
                    }
                    Button("Delete team…", role: .destructive) { isConfirmingDelete = true }
                } label: {
                    Text("Manage")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.Palette.muted)
                }
                .plainMenuChrome()
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var roster: some View {
        VStack(spacing: 0) {
            ForEach(members ?? []) { member in
                HStack(spacing: 10) {
                    Text(member.displayName ?? member.email)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.ink)
                    Text(member.role.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.muted)
                    Spacer(minLength: 8)
                    if canAdminister {
                        Button("Remove") { remove(member) }
                            .font(.system(size: 11.5))
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.Palette.danger)
                    }
                }
                .padding(.leading, 37)
                .padding(.trailing, 14)
                .padding(.vertical, 7)
            }
            if members?.isEmpty == true {
                Text("Nobody in this team yet.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 37)
                    .padding(.bottom, 7)
            }
            if canAdminister, !unassigned.isEmpty {
                Menu {
                    ForEach(unassigned) { candidate in
                        Button(candidate.displayName ?? candidate.email) { add(candidate) }
                    }
                } label: {
                    Text("Add someone")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.Palette.muted)
                }
                .plainMenuChrome()
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 37)
                .padding(.bottom, 10)
            }
        }
    }

    private func toggle() {
        isExpanded.toggle()
        guard isExpanded, members == nil else { return }
        Task { await load() }
    }

    private func startRename() {
        draftName = team.name
        isRenaming = true
    }

    private func commitRename() {
        isRenaming = false
        guard draftName != team.name else { return }
        rename(draftName)
    }
}
