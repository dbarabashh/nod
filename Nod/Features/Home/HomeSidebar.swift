import SwiftUI

/// The main window's sidebar: what you can do, what you've grouped, and what
/// you were last talking about — plus the state Nod is in (ambient on or off,
/// which plan) pinned at the bottom where a status belongs.
struct HomeSidebar: View {
    let surface: MainWindowView.Surface
    let onSelect: (MainWindowView.Surface) -> Void
    let onNewChat: () -> Void
    let onOpenProject: (SessionLabel) -> Void
    let onOpenThread: (UUID) -> Void
    /// Bring the panel up with a kind already chosen. It stops at the panel
    /// rather than starting: consent, permissions and the language prompt live
    /// there, and a sidebar button must not skip them.
    let onCapture: () -> Void
    let panelShortcut: String

    @EnvironmentObject private var labelStore: LabelStore
    @EnvironmentObject private var organizations: OrganizationService
    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var threads: KnowledgeThreadStore
    @EnvironmentObject private var chat: KnowledgeChatStore
    @EnvironmentObject private var demoPlayback: DemoPlayback

    @State private var isAddingProject = false
    @State private var newProjectName = ""
    @State private var newProjectColor = LabelPalette.default
    @State private var editingLabel: SessionLabel?
    @State private var confirmingDeleteThread: UUID?
    /// "3 sessions · 2h ago" per project, counted over LIVE sessions only — the
    /// raw link tally includes rows pointing at trashed sessions, which reads as
    /// "5 sessions" on a project that opens showing four.
    @State private var projectSubtitles: [UUID: String] = [:]
    /// Shown once: the panel no longer appears by itself at launch, so the
    /// shortcut that summons it has to be said out loud somewhere.
    @AppStorage("home.captureHintSeen") private var captureHintSeen = false

    static let width: CGFloat = 232
    /// Clear band at the top for the window's traffic lights — the window has no
    /// toolbar, so they float over the content's top-left corner.
    private static let topBand: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Self.topBand)
            OrgSidebarRow()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    captureButton
                    captureHint
                    // A wider gap than the rows keep between themselves: the
                    // primary action and a list of places are not peers.
                    Color.clear.frame(height: 20)
                    chatRow
                    dailyModesRow
                    SidebarNavRow(
                        title: "Sessions",
                        icon: "nc-layers-3",
                        isSelected: surface == .sessions,
                        action: { onSelect(.sessions) }
                    )
                    // A place of its own: what Nod extracted is one of the
                    // things the main window is for, and the only route in used
                    // to be a header inside the attention list — which left the
                    // full list reachable but unfindable.
                    ActionsSidebarRow(
                        isSelected: surface == .actionItems,
                        onSelect: { onSelect(.actionItems) }
                    )
                    projectsSection
                    sharedProjectsSection
                    threadsSection
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            Spacer(minLength: 0)
            HomeSidebarFooter(surface: surface, onSelect: onSelect)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.white.opacity(0.02))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.Palette.border)
                .frame(width: 0.5)
                .frame(maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
        .onAppear(perform: recountProjects)
        .onChange(of: labelStore.assignments) { _ in recountProjects() }
        .onChange(of: meetingStore.digestKey) { _ in recountProjects() }
    }

    private func recountProjects() {
        var tally: [UUID: Int] = [:]
        var latest: [UUID: Date] = [:]
        for meeting in meetingStore.meetings {
            for labelID in labelStore.assignments[meeting.id] ?? [] {
                tally[labelID, default: 0] += 1
                if meeting.startedAt > (latest[labelID] ?? .distantPast) {
                    latest[labelID] = meeting.startedAt
                }
            }
        }
        projectSubtitles = tally.reduce(into: [:]) { result, entry in
            let (labelID, count) = entry
            var parts = ["\(count) \(count == 1 ? "session" : "sessions")"]
            if let date = latest[labelID] { parts.append(Meeting.ago(date)) }
            result[labelID] = parts.joined(separator: " · ")
        }
    }

    // MARK: - Primary action

    /// The app's main verb. A plain button, not the pull-down it used to be:
    /// there is one kind of capture now, and a chevron over a one-item menu
    /// promises a choice that isn't there.
    private var captureButton: some View {
        Button {
            // Reaching capture is the lesson learned; the hint has served.
            captureHintSeen = true
            onCapture()
        } label: {
            HStack(spacing: 8) {
                Image("nc-plus")
                    .icon(13)
                Text("Start Nod")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.GlassButton.text)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            // The app's primary-action surface, which every other call to
            // action already wears and the main verb did not. A capsule, not the
            // chip rectangle the nav rows use: an earlier attempt at a light
            // fill read as "the section you're in" precisely because it kept
            // their shape, so the two are separated by form rather than by
            // brightness.
            .glassButtonSurface(Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Start Nod  ·  \(panelShortcut)")
    }

    @ViewBuilder
    private var captureHint: some View {
        if !captureHintSeen {
            HStack(alignment: .top, spacing: 6) {
                Text("Press \(panelShortcut) any time to capture — Nod stays out of the way until you do.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button { captureHintSeen = true } label: {
                    Image("nc-xmark")
                        .icon(8)
                        .foregroundStyle(Theme.Palette.muted)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Got it")
            }
            .padding(.horizontal, 4)
            .padding(.top, 6)
            .transition(.opacity)
        }
    }

    // MARK: - Navigation rows

    /// Asking is the verb; the Chats list below is the history.
    ///
    /// This was two controls — a row that returned you to the chat you had, and
    /// a ＋ that opened an empty one — which shared a destination and read as
    /// one button drawn twice. The row that returns you was the redundant half:
    /// a thread is saved the moment it has a message in it, so every
    /// conversation worth returning to is already a row in Chats, with the open
    /// one marked. What no list can offer is the empty page, so that is what
    /// the row does.
    ///
    /// Nothing is lost by clicking it: a chat with anything in it is in the
    /// list, and a chat with nothing in it is left alone (`startNewThread`).
    private var chatRow: some View {
        // "Chat" names the interface; "Ask Nod" names the job — and it's the
        // phrase the composer already uses ("Ask across all memory").
        //
        // Selected only while the new chat is still unsaved: once it has been
        // sent it owns a row in Chats, and that row is where "you are here"
        // belongs.
        SidebarNavRow(
            title: "Ask NOD",
            icon: "nc-sparkle-3",
            isSelected: surface == .chat && chat.threadID == nil,
            action: onNewChat
        )
    }

    /// Only shown while a scripted scenario is armed (Settings → Demo) — the
    /// seven scripted modes behind it have nothing to show a real account, so
    /// the row itself must not outlive the thing it opens.
    @ViewBuilder
    private var dailyModesRow: some View {
        if demoPlayback.armed != nil {
            SidebarNavRow(
                title: "Today",
                icon: "nc-window-chart-line",
                isSelected: surface == .dailyModes,
                action: { onSelect(.dailyModes) }
            )
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        SectionLabel(title)
            .padding(.horizontal, 9)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    // MARK: - Projects

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Projects")
            ForEach(labelStore.labels.filter(labelStore.isOwn)) { label in
                projectRow(label)
            }
            if let error = labelStore.lastError {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
            }
            addProjectRow
        }
    }

    /// Folders a colleague shared, kept apart from your own.
    ///
    /// They used to sit in the same list behind a small icon, which said almost
    /// nothing: the one thing a person needs to know about somebody else's
    /// project is that it *is* somebody else's, and a badge at the end of a row
    /// is not where that lands. A section says it once, in the place people read
    /// first.
    @ViewBuilder
    private var sharedProjectsSection: some View {
        let shared = labelStore.labels.filter { !labelStore.isOwn($0) }
        if !shared.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader("Shared with you")
                ForEach(shared) { label in
                    projectRow(label)
                }
            }
        }
    }

    /// Who a folder of yours is shared with, in the words of the menu that
    /// shared it. Absent when nobody — most projects are nobody's but yours, and
    /// a subtitle saying so on every row would be noise.
    private func shareAudience(for label: SessionLabel) -> String? {
        let shares = labelStore.shares[label.id] ?? []
        guard !shares.isEmpty else { return nil }
        let names = shares.compactMap { share -> String? in
            if let teamID = share.teamID {
                return organizations.teams.first { $0.id == teamID }?.name
            }
            if let orgID = share.orgID {
                return organizations.memberships.first { $0.id == orgID }?.organization.name
            }
            return nil
        }
        guard !names.isEmpty else { return nil }
        return "Shared with " + names.sorted().joined(separator: ", ")
    }

    private func projectRow(_ label: SessionLabel) -> some View {
        Button { onOpenProject(label) } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(label.swatchColor)
                    .frame(width: 8, height: 8)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    // A project is a live context, not a folder — say how much
                    // is in it and when it last moved.
                    if let subtitle = shareAudience(for: label) ?? projectSubtitles[label.id] {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.Palette.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if labelStore.isShared(label.id), labelStore.isOwn(label) {
                    Image("nc-users")
                        .icon(10)
                        .foregroundStyle(Theme.Palette.muted)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(Theme.Palette.ink.opacity(0.72))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if labelStore.isOwn(label) {
                Button("Edit project…") { editingLabel = label }
                shareMenu(for: label)
            }
        }
        .popover(isPresented: Binding(
            get: { editingLabel?.id == label.id },
            set: { if !$0 { editingLabel = nil } }
        ), arrowEdge: .trailing) {
            LabelEditor(label: label) { editingLabel = nil }
                .frame(width: 240)
        }
    }

    /// Sharing lives on the folder because that is the object being shared.
    /// Absent for someone in no organization: there is nobody to share with, and
    /// a menu item that opens onto an empty list is a question with no answer.
    @ViewBuilder
    private func shareMenu(for label: SessionLabel) -> some View {
        if let orgID = organizations.activeOrgID, let membership = organizations.activeMembership {
            let teams = organizations.teams(in: orgID)
            let existing = labelStore.shares[label.id] ?? []
            Divider()
            ForEach(teams) { team in
                if let share = existing.first(where: { $0.teamID == team.id }) {
                    Button("Stop sharing with \(team.name)") {
                        Task { await labelStore.unshare(share) }
                    }
                } else {
                    Button("Share with \(team.name)") {
                        Task { await labelStore.share(label.id, withTeam: team.id, org: nil) }
                    }
                }
            }
            if let share = existing.first(where: { $0.orgID != nil }) {
                Button("Stop sharing with \(membership.organization.name)") {
                    Task { await labelStore.unshare(share) }
                }
            } else {
                Button("Share with all of \(membership.organization.name)") {
                    Task { await labelStore.share(label.id, withTeam: nil, org: orgID) }
                }
            }
        }
    }

    private var addProjectRow: some View {
        Button { isAddingProject = true } label: {
            HStack(spacing: 9) {
                Image("nc-plus")
                    .icon(11)
                    .frame(width: 16)
                Text("Add project")
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.Palette.muted)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isAddingProject, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Project name", text: $newProjectName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(createProject)
                LabelSwatchRow(selection: $newProjectColor)
                HStack {
                    Spacer(minLength: 0)
                    Button("Cancel") { isAddingProject = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Create", action: createProject)
                        .keyboardShortcut(.defaultAction)
                        .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .font(.system(size: 12.5))
            }
            .padding(12)
            .frame(width: 240)
        }
    }

    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let color = newProjectColor
        isAddingProject = false
        newProjectName = ""
        newProjectColor = LabelPalette.default
        Task { try? await labelStore.create(name: name, color: color) }
    }

    // MARK: - Recent chats

    @ViewBuilder
    private var threadsSection: some View {
        if !threads.threads.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader("Chats")
                ForEach(threads.threads) { thread in
                    threadRow(thread)
                }
            }
        }
    }

    /// The confirm pair are siblings of the row, not children of it: nested in
    /// the row's own button they sat inside its hit area, so confirming a
    /// delete also opened the thread being deleted.
    private func threadRow(_ thread: KnowledgeThreadStore.Thread) -> some View {
        let isOpen = chat.threadID == thread.id && surface == .chat
        return HStack(spacing: 9) {
            Image("nc-msgs")
                .icon(11)
                .frame(width: 16)
            Text(thread.displayTitle)
                .font(.system(size: 12.5, weight: isOpen ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
            if confirmingDeleteThread == thread.id {
                InlineConfirmButtons(
                    confirmIcon: "nc-trash",
                    confirmHelp: "Delete this chat",
                    cancelHelp: "Keep it",
                    onConfirm: { delete(thread) },
                    onCancel: { confirmingDeleteThread = nil }
                )
            }
        }
        .foregroundStyle(Theme.Palette.ink.opacity(isOpen ? 0.95 : 0.7))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                .fill(Theme.Palette.surfaceStrong)
                .opacity(isOpen ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            confirmingDeleteThread = nil
            onOpenThread(thread.id)
        }
        .contextMenu {
            Button(role: .destructive) { confirmingDeleteThread = thread.id } label: {
                IconLabel(title: "Delete", icon: "nc-trash")
            }
        }
    }

    private func delete(_ thread: KnowledgeThreadStore.Thread) {
        confirmingDeleteThread = nil
        // Deleting what's on screen would leave the reader looking at a
        // conversation that no longer exists.
        if chat.threadID == thread.id {
            chat.startNewThread()
        }
        Task { await threads.delete(thread.id) }
    }
}
