import SwiftUI

/// Naming a project, colouring it, and deciding who else can read it.
///
/// Both halves used to be `.popover`s hung off the sidebar, and a popover
/// brings its own arrow, its own material and AppKit's own accent with it — so
/// a form of two fields read as a system menu that had appeared near Nod
/// rather than as part of it. It wears the window's own backdrop now, and its
/// field and buttons are the app's rather than the system's.
///
/// Sharing moved in here from a context submenu. Handing a project to a team
/// was previously something you could only do *after* making it, from a menu
/// you had to know was there — while the moment a person actually decides who
/// a project is for is the moment they name it.
///
/// `LabelEditor` still exists for the meeting detail's label picker, where the
/// editor opens *inside* a popover the person is already in. A sheet over a
/// popover would be a modal on top of a modal, which is worse than the
/// inconsistency.
struct ProjectSheet: View {
    enum Mode: Equatable {
        case create
        case edit(SessionLabel)
    }

    /// Who a project can be handed to. Deliberately not a person: the audience
    /// on `folder_shares` is a team or an organization and nothing else
    /// (`num_nonnulls(team_id, org_id) = 1`), so naming individuals here would
    /// be a promise the schema cannot keep.
    private enum Audience: Hashable {
        case team(UUID)
        case organization
    }

    let mode: Mode

    @EnvironmentObject private var labelStore: LabelStore
    @EnvironmentObject private var organizations: OrganizationService
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var color: String
    @State private var audiences: Set<Audience> = []
    @State private var teamQuery = ""
    /// The order the team list is drawn in, fixed when the sheet opens.
    ///
    /// Sorting live by what is ticked reads well in a screenshot and badly
    /// under a cursor: the row you just ticked jumps to the top, and the one
    /// you were aiming at next slides into its place. Frozen, the list answers
    /// "what did I pick" at the top without moving while you pick.
    @State private var teamOrder: [UUID] = []

    /// Seeded once from the shares already on the project. Re-seeding on every
    /// appearance would undo a box the person had just unticked.
    @State private var didSeedAudiences = false
    @FocusState private var nameFocused: Bool

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _color = State(initialValue: LabelPalette.default)
        case let .edit(label):
            _name = State(initialValue: label.name)
            _color = State(initialValue: label.color)
        }
    }

    private var editing: SessionLabel? {
        if case let .edit(label) = mode { return label }
        return nil
    }

    private var isNamed: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var teams: [Team] {
        guard let orgID = organizations.activeOrgID else { return [] }
        return organizations.teams(in: orgID)
    }

    private var isSearchable: Bool {
        ProjectAudiences.isSearchable(teamCount: teams.count)
    }

    private var listedTeams: [Team] {
        ProjectAudiences.listed(teams, order: teamOrder, query: teamQuery)
    }

    /// Only for somebody in an organization. Alone, there is nobody to share
    /// with, and a section listing no audiences is a question with no answer.
    private var canShare: Bool {
        organizations.activeMembership != nil
    }

    /// Which teams the project is already shared with, for the opening rank.
    private var sharedTeamIDs: Set<UUID> {
        Set(audiences.compactMap { audience in
            if case let .team(id) = audience { return id }
            return nil
        })
    }

    private var existingShares: [FolderShare] {
        guard let label = editing else { return [] }
        return labelStore.shares[label.id] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.Palette.border)
            form
            Divider().overlay(Theme.Palette.border)
            footer
        }
        .frame(width: 380)
        .background(WindowBackdrop().ignoresSafeArea())
        .onAppear(perform: seedAudiences)
    }

    private var header: some View {
        SheetHeader(
            title: editing == nil ? "New project" : "Edit project",
            subtitle: "A project groups sessions, and scopes what Ask Nod reads when you ask about it."
        )
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Name")
                nameField
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Colour")
                LabelSwatchRow(selection: $color)
            }
            if canShare {
                shareSection
            }
            if let error = labelStore.lastError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    /// The whole organization sits above the teams rather than among them: it
    /// is a different kind of audience — the schema stores it in its own column
    /// — and it is the one choice that makes every team row below it moot.
    private var shareSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Share with")
            if let membership = organizations.activeMembership {
                audienceRow("Everyone at \(membership.organization.name)", audience: .organization)
            }
            if !teams.isEmpty {
                if isSearchable {
                    teamSearchField
                }
                teamList
            }
            Text("Anyone you share with can read this project's sessions. Only you can rename, delete or re-share it.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var teamList: some View {
        let rows = listedTeams
        if rows.isEmpty {
            Text("No team matches “\(teamQuery.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.muted)
                .padding(.vertical, 2)
        } else if isSearchable {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows) { team in
                        audienceRow(team.name, audience: .team(team.id))
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(maxHeight: ProjectAudiences.listHeight)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { team in
                    audienceRow(team.name, audience: .team(team.id))
                }
            }
        }
    }

    private var teamSearchField: some View {
        SearchField(prompt: "Search \(teams.count) teams", text: $teamQuery, size: .compact)
            .padding(.vertical, 2)
    }

    /// The app's field, not the system's. `.roundedBorder` draws AppKit's blue
    /// focus ring, which is the single loudest thing about a form that is
    /// otherwise all Nod's own colours.
    private var nameField: some View {
        TextField("Project name", text: $name)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Theme.Palette.ink)
            .focused($nameFocused)
            .onSubmit(commit)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .fieldSurface(focused: nameFocused)
    }

    private func audienceRow(_ title: String, audience: Audience) -> some View {
        let isOn = audiences.contains(audience)
        return Button {
            if isOn { audiences.remove(audience) } else { audiences.insert(audience) }
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isOn ? AnyShapeStyle(Theme.GlassButton.fill) : AnyShapeStyle(Theme.Palette.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Theme.Palette.border, lineWidth: 0.5)
                    )
                    .overlay {
                        if isOn {
                            Image("nc-check")
                                .icon(9)
                                .foregroundStyle(Theme.GlassButton.text)
                        }
                    }
                    .frame(width: 15, height: 15)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
    }

    private var footer: some View {
        SheetFooter(
            delete: editing == nil ? nil : TitledAction("Delete", action: delete),
            cancel: { dismiss() },
            primary: TitledAction(editing == nil ? "Create" : "Save", isEnabled: isNamed, action: commit)
        )
    }

    private func seedAudiences() {
        guard !didSeedAudiences else { return }
        didSeedAudiences = true
        audiences = Set(existingShares.compactMap(Self.audience(of:)))
        teamOrder = ProjectAudiences.ranked(teams, sharedWith: sharedTeamIDs).map(\.id)
    }

    private static func audience(of share: FolderShare) -> Audience? {
        if let teamID = share.teamID { return .team(teamID) }
        return share.orgID == nil ? nil : .organization
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let chosenColor = color
        let wanted = audiences
        let label = editing
        let shares = existingShares
        let orgID = organizations.activeOrgID
        dismiss()
        Task {
            let target: SessionLabel?
            if let label {
                try? await labelStore.update(label.id, name: trimmed, color: chosenColor)
                target = label
            } else {
                target = try? await labelStore.create(name: trimmed, color: chosenColor)
            }
            guard let target else { return }
            // Withdrawn first: a project handed to both a team and the whole
            // organization reads as the wider one, so removing before adding
            // keeps the narrower answer from being briefly wrong.
            for share in shares where !wanted.contains(Self.audience(of: share) ?? .organization) {
                await labelStore.unshare(share)
            }
            let already = Set(shares.compactMap(Self.audience(of:)))
            for audience in wanted.subtracting(already) {
                switch audience {
                case let .team(teamID):
                    await labelStore.share(target.id, withTeam: teamID, org: nil)
                case .organization:
                    guard let orgID else { continue }
                    await labelStore.share(target.id, withTeam: nil, org: orgID)
                }
            }
        }
    }

    private func delete() {
        guard let label = editing else { return }
        dismiss()
        Task { try? await labelStore.delete(label.id) }
    }
}
