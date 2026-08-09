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
    @Binding var contextCollapsed: Bool

    @EnvironmentObject private var labelStore: LabelStore
    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var threads: KnowledgeThreadStore
    @EnvironmentObject private var chat: KnowledgeChatStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var entitlements: EntitlementService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isAddingProject = false
    @State private var newProjectName = ""
    @State private var newProjectColor = LabelPalette.default
    @State private var editingLabel: SessionLabel?
    @State private var confirmingDeleteThread: UUID?
    @State private var newChatHovering = false
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
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    captureButton
                    captureHint
                    // The gap is the point: an action and a list of places are
                    // not three peers. Without it the white primary button reads
                    // as "the section you're in".
                    Color.clear.frame(height: 14)
                    chatRow
                    navRow(
                        "Sessions",
                        icon: "nc-layers-3",
                        isSelected: surface == .sessions,
                        action: { onSelect(.sessions) }
                    )
                    projectsSection
                    threadsSection
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            Spacer(minLength: 0)
            footer
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
                    .font(.system(size: 12, weight: .bold))
                Text("Capture")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.Palette.ink)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            // Filled and bordered, so it reads as a control rather than a
            // heading — but neutral, not the white pill, which made the main
            // action look like the section the user is currently in.
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                    .fill(Theme.Palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                            .stroke(Theme.Palette.borderStrong, lineWidth: 0.5)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Capture a meeting  ·  \(panelShortcut)")
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
                        .font(.system(size: 8, weight: .bold))
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

    /// Going back to the conversation and starting a fresh one are different
    /// intents, so they're different targets: the row returns you to the chat
    /// you had, the ＋ opens an empty one.
    private var chatRow: some View {
        HStack(spacing: 4) {
            // "Chat" names the interface; "Ask Nod" names the job — and it's
            // the phrase the composer already uses ("Ask across all memory").
            navRow(
                "Ask NOD",
                icon: "nc-sparkle-3",
                isSelected: surface == .chat,
                action: { onSelect(.chat) }
            )
            // Carries its own surface at rest: as a bare glyph it read as
            // decoration beside the row and users didn't find it.
            Button(action: onNewChat) {
                Image("nc-pen-writing")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(newChatHovering ? Theme.Palette.ink : Theme.Palette.ink.opacity(0.72))
                    // Stretches to the row beside it where the stack has a
                    // height to give — inside a `ScrollView` it doesn't, and
                    // `maxHeight` alone collapses to the glyph.
                    .frame(width: 30)
                    .frame(minHeight: 30, maxHeight: .infinity)
                    .hoverSurface(
                        newChatHovering,
                        in: RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous),
                        reduceMotion: reduceMotion
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { newChatHovering = $0 }
            .linkCursor()
            .help("New chat")
        }
    }

    private func navRow(
        _ title: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Theme.Palette.ink : Theme.Palette.ink.opacity(0.72))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                    .fill(Theme.Palette.surfaceStrong)
                    .opacity(isSelected ? 1 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            ForEach(labelStore.labels) { label in
                projectRow(label)
            }
            addProjectRow
        }
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
                    if let subtitle = projectSubtitles[label.id] {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.Palette.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.Palette.ink.opacity(0.72))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit project…") { editingLabel = label }
        }
        .popover(isPresented: Binding(
            get: { editingLabel?.id == label.id },
            set: { if !$0 { editingLabel = nil } }
        ), arrowEdge: .trailing) {
            LabelEditor(label: label) { editingLabel = nil }
                .frame(width: 240)
        }
    }

    private var addProjectRow: some View {
        Button { isAddingProject = true } label: {
            HStack(spacing: 9) {
                Image("nc-plus")
                    .font(.system(size: 11, weight: .semibold))
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
                .font(.system(size: 11, weight: .medium))
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
                Label("Delete", image: "nc-trash")
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

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 2) {
            Divider()
                .overlay(Theme.Palette.border)
                .padding(.bottom, 6)
            if contextCollapsed {
                navRow(
                    "Needs your attention",
                    icon: "nc-sidebar-right",
                    isSelected: false,
                    action: {
                        withAnimation(.standard(reduceMotion: reduceMotion)) { contextCollapsed = false }
                    }
                )
                .transition(.opacity)
            }
            // Takes the service from the environment itself. Holding it here
            // instead meant every capture tick — one every 5 seconds while
            // ambient context runs — invalidated the whole sidebar body to
            // redraw one 30pt row.
            AmbientContextSidebarRow()
            navRow(
                "Settings",
                icon: "nc-gear-2",
                isSelected: surface == .settings,
                action: { onSelect(.settings) }
            )
            accountRow
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private var accountRow: some View {
        Button { onSelect(.settings) } label: {
            HStack(spacing: 9) {
                Image("nc-user")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Theme.Palette.muted)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(displayName)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                        .lineLimit(1)
                    Text(planLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Account and plan")
    }

    private var displayName: String {
        let name = profileStore.profile?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Your account" : name
    }

    /// Reads the plan the server resolved. Unresolved (offline, first launch)
    /// says nothing rather than guessing a tier the user isn't on.
    private var planLabel: String {
        guard let entitlement = entitlements.entitlement else { return "—" }
        let plan = entitlement.plan.capitalized
        return entitlement.status == .trialing ? "\(plan) · trial" : plan
    }
}
