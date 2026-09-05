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
    @State private var editingLabel: SessionLabel?
    @State private var confirmingDeleteThread: UUID?
    /// "3 sessions · 2h ago" per project, counted over LIVE sessions only — the
    /// raw link tally includes rows pointing at trashed sessions, which reads as
    /// "5 sessions" on a project that opens showing four.
    @State private var projectSubtitles: [UUID: String] = [:]
    /// Shown once: the panel no longer appears by itself at launch, so the
    /// shortcut that summons it has to be said out loud somewhere.
    @AppStorage("home.captureHintSeen") private var captureHintSeen = false

    static let width: CGFloat = Theme.Layout.sidebar
    /// Clear band at the top for the window's traffic lights — the window has no
    /// toolbar, so they float over the content's top-left corner.
    private static let topBand: CGFloat = Theme.Space.x10

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Self.topBand)
            OrgSidebarRow()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    // The one capture door, everywhere — Today used to carry
                    // its own header button for the no-meeting-coming case,
                    // which made this row disappear exactly where a person
                    // would look for it first.
                    captureButton
                    captureHint
                    // A wider gap than the rows keep between themselves: the
                    // primary action and a list of places are not peers.
                    Color.clear.frame(height: 20)
                    SidebarNavRow(
                        title: "Today",
                        icon: "nc-sparkle-3",
                        isSelected: surface == .today,
                        action: { onSelect(.today) }
                    )
                    chatRow
                    demoDailyModesRow
                    // "Memory" rather than "Sessions": the list is the same,
                    // but the product's claim is a working memory, and the
                    // sidebar is where that claim is either made or dropped.
                    SidebarNavRow(
                        title: "Memory",
                        icon: "nc-layers-3",
                        isSelected: surface == .sessions,
                        action: { onSelect(.sessions) }
                    )
                    // A destination beside Memory rather than a segment above
                    // it: restoring and destroying are not things you do to a
                    // live session, so this is a different place to be, and it
                    // costs the list nothing to sit here.
                    SidebarNavRow(
                        title: "Beats",
                        icon: "nc-stopwatch",
                        isSelected: surface == .beats,
                        action: { onSelect(.beats) }
                    )
                    SidebarNavRow(
                        title: "Trash",
                        icon: "nc-trash",
                        isSelected: surface == .trash,
                        action: { onSelect(.trash) }
                    )
                    projectsSection
                    sharedProjectsSection
                    threadsSection
                }
                .padding(.horizontal, Theme.Space.x3)
                .padding(.bottom, Theme.Space.x3)
            }
            Spacer(minLength: 0)
            HomeSidebarFooter(surface: surface)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Palette.overlay.opacity(0.02))
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
                // A microphone, not a plus: "+" is the glyph every other row in
                // this sidebar uses for adding a thing, and a button that opens
                // a recording read as one more "new item" because of it.
                Image("nc-mic")
                    .icon(Theme.Control.iconMicro)
                // "New capture", not "Start Nod": Today carries its own,
                // meeting-named Start button, and two dark buttons doing one
                // thing taught people the sidebar one was something else.
                Text("New capture")
                    .textStyle(Theme.Typography.uiEmphasis.weight(.semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.GlassButton.text)
            .padding(.horizontal, Theme.Space.x3)
            .frame(height: Theme.Control.heightCompact)
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
            .padding(.horizontal, Theme.Space.x1)
            .padding(.top, Theme.Space.x2)
            .transition(.opacity)
        }
    }

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
            icon: "nc-magnifier",
            isSelected: surface == .chat && chat.threadID == nil,
            action: onNewChat
        )
    }

    /// The scripted seven modes, and only while a scenario is armed
    /// (Settings → Demo) — they have nothing to show a real account, so the row
    /// must not outlive the thing it opens.
    @ViewBuilder
    private var demoDailyModesRow: some View {
        if demoPlayback.armed != nil {
            SidebarNavRow(
                title: "Daily modes",
                icon: "nc-sparkle-3",
                isSelected: surface == .demoDailyModes,
                action: { onSelect(.demoDailyModes) }
            )
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        SectionLabel(title)
            .padding(.horizontal, Theme.Space.x2)
            .padding(.top, Theme.Space.x4)
            .padding(.bottom, Theme.Space.x1)
    }

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
                    .padding(.horizontal, Theme.Space.x2)
                    .padding(.vertical, Theme.Space.x1)
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

    /// Who a folder is shared with, in the words of the menu that shared it —
    /// or, for somebody else's, how it reached you.
    ///
    /// Both halves matter because two people in one organization routinely name
    /// a project the same thing: a colleague's "Nod" and your own "Nod" sat in
    /// the sidebar as two identical rows, and the only one you could share was
    /// the one you had made. Absent when nobody — most projects are nobody's but
    /// yours, and a subtitle saying so on every row would be noise.
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
        let audience = names.sorted().joined(separator: ", ")
        return labelStore.isOwn(label) ? "Shared with \(audience)" : "Shared via \(audience)"
    }

    /// A project is a live context, not a folder — the subtitle says how much
    /// is in it and when it last moved.
    private func projectRow(_ label: SessionLabel) -> some View {
        SidebarNavRow(
            title: label.name,
            subtitle: shareAudience(for: label) ?? projectSubtitles[label.id],
            verticalPadding: 5
        ) {
            onOpenProject(label)
        } leading: {
            Circle()
                .fill(label.swatchColor)
                .frame(width: 8, height: 8)
        } trailing: {
            if labelStore.isShared(label.id), labelStore.isOwn(label) {
                Image("nc-users")
                    .icon(10)
                    .foregroundStyle(Theme.Palette.muted)
                    .accessibilityHidden(true)
            }
        }
        .contextMenu {
            if labelStore.isOwn(label) {
                // Sharing used to be a submenu here. It lives in the sheet now,
                // beside the name and the colour — who a project is for is
                // decided when it is made far more often than it is changed
                // afterwards, and a submenu is not where anyone looks first.
                Button("Edit project…") { editingLabel = label }
            } else {
                // A context menu with nothing in it does not open at all, so a
                // right-click on a colleague's project answered nothing — which
                // reads as a broken Share rather than as "not yours to share".
                Button("Only its owner can share this") {}
                    .disabled(true)
            }
        }
        .sheet(isPresented: Binding(
            get: { editingLabel?.id == label.id },
            set: { if !$0 { editingLabel = nil } }
        )) {
            ProjectSheet(mode: .edit(label))
        }
    }

    private var addProjectRow: some View {
        SidebarNavRow(title: "Add project", tone: .quiet) {
            isAddingProject = true
        } leading: {
            Image("nc-plus").icon(11)
        }
        .sheet(isPresented: $isAddingProject) {
            ProjectSheet(mode: .create)
        }
    }

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
        SidebarRowLabel(
            title: thread.displayTitle,
            isSelected: chat.threadID == thread.id && surface == .chat
        ) {
            Image("nc-msgs").icon(11)
        } trailing: {
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
