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
    let onCapture: (SessionKind) -> Void
    let panelShortcut: String
    @Binding var contextCollapsed: Bool

    @EnvironmentObject private var labelStore: LabelStore
    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var threads: KnowledgeThreadStore
    @EnvironmentObject private var chat: KnowledgeChatStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var entitlements: EntitlementService
    @EnvironmentObject private var screenContext: ScreenContextService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    @State private var isCaptureOpen = false
    @State private var hoveredCaptureKind: SessionKind?

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
                        icon: "rectangle.stack",
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

    /// Capture, not Record: the panel this opens takes a meeting, a voice note
    /// or media, and "record" names only the first of the three.
    ///
    /// A menu, not a plain button: the three kinds are the reason the word is
    /// "capture", and a chevron says so before the click. The ＋ and the chevron
    /// together also stop the white pill from reading as a selected nav row —
    /// this is the app's main verb, not the section you're in.
    private var captureButton: some View {
        Button {
            withAnimation(.standard(reduceMotion: reduceMotion)) {
                isCaptureOpen.toggle()
                // Opening it is the lesson learned; no need to keep the hint.
                captureHintSeen = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                Text("Capture")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer(minLength: 0)
                // One symbol rotated, not two swapped: swapping `chevron.down`
                // for `chevron.up` is a cut, and every other state change in the
                // app moves.
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.Palette.muted)
                    .rotationEffect(.degrees(isCaptureOpen ? 180 : 0))
            }
            .foregroundStyle(Theme.Palette.ink)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            // Filled and bordered, so it reads as a control rather than a
            // heading — but neutral, not the white pill, which made the main
            // action look like the section the user is currently in.
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isCaptureOpen ? Theme.Palette.surfaceStrong : Theme.Palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Theme.Palette.borderStrong, lineWidth: 0.5)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Capture a meeting, voice note, or media  ·  \(panelShortcut)")
        .popover(isPresented: $isCaptureOpen, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            captureMenu
        }
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
                    Image(systemName: "xmark")
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

    /// The kinds, drawn by us rather than as an `NSMenu`: a native menu can't be
    /// held to the trigger's width, can't carry the row hover, and floated at
    /// its own size beside a 232pt sidebar it read as unrelated to the button
    /// that opened it.
    private var captureMenu: some View {
        VStack(spacing: 2) {
            ForEach(SessionKind.allCases) { kind in
                captureRow(kind)
            }
        }
        .padding(6)
        .frame(width: Self.width - 20)
        // No palette fill: the popover already draws the system's vibrancy, and
        // painting `bgSoft` over it put a flat navy slab in a window made of
        // warm grey glass. A thin white lift is all it needs to sit above the
        // sidebar without leaving the material.
        .background(Color.white.opacity(0.04))
    }

    private func captureRow(_ kind: SessionKind) -> some View {
        Button {
            withAnimation(.standard(reduceMotion: reduceMotion)) { isCaptureOpen = false }
            onCapture(kind)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: kind.icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.72))
                    .frame(width: 16)
                Text(kind.captureMenuTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.9))
                Spacer(minLength: 0)
            }
            // Same row metrics as the navigation rows below it — the menu is
            // part of the sidebar's language, not a control from another app.
            .padding(.horizontal, 9)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .hoverHighlight(
                hoveredCaptureKind == kind,
                cornerRadius: Theme.Radii.chip,
                reduceMotion: reduceMotion
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { hoveredCaptureKind = kind } else if hoveredCaptureKind == kind { hoveredCaptureKind = nil }
        }
    }

    // MARK: - Navigation rows

    /// Going back to the conversation and starting a fresh one are different
    /// intents, so they're different targets: the row returns you to the chat
    /// you had, the ＋ opens an empty one.
    private var chatRow: some View {
        HStack(spacing: 0) {
            // "Chat" names the interface; "Ask Nod" names the job — and it's
            // the phrase the composer already uses ("Ask across all memory").
            navRow(
                "Ask NOD",
                icon: "sparkles",
                isSelected: surface == .chat,
                action: { onSelect(.chat) }
            )
            Button(action: onNewChat) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                Image(systemName: "plus")
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
            Image(systemName: "bubble.left")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 16)
            Text(thread.displayTitle)
                .font(.system(size: 12.5, weight: isOpen ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
            if confirmingDeleteThread == thread.id {
                InlineConfirmButtons(
                    confirmIcon: "trash.fill",
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
                Label("Delete", systemImage: "trash")
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
                    icon: "sidebar.right",
                    isSelected: false,
                    action: {
                        withAnimation(.standard(reduceMotion: reduceMotion)) { contextCollapsed = false }
                    }
                )
                .transition(.opacity)
            }
            ambientRow
            navRow(
                "Settings",
                icon: "gearshape",
                isSelected: surface == .settings,
                action: { onSelect(.settings) }
            )
            accountRow
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    /// Ambient capture is the one switch that widens what Nod reads beyond a
    /// recording, so its state is visible without opening anything. The detail —
    /// what's excluded, how long it's kept — stays in Settings › Privacy.
    private var ambientRow: some View {
        Button(action: toggleAmbient) {
            HStack(spacing: 9) {
                Circle()
                    .fill(ambientTint)
                    .frame(width: 7, height: 7)
                    .frame(width: 16)
                // The same name the setting carries in Settings › Privacy and in
                // the privacy policy — one feature, one word for it.
                Text("Ambient context")
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(ambientOn ? "On" : "Off")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
            }
            .foregroundStyle(Theme.Palette.ink.opacity(0.72))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                    .fill(Theme.Palette.surface)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(ambientHelp)
    }

    /// The service publishes the switch, so there's nothing to mirror here.
    private var ambientOn: Bool {
        screenContext.isAmbientEnabled
    }

    /// Turning it OFF is always one click — a kill switch you have to go
    /// looking for is not a kill switch. Turning it ON routes to Settings ›
    /// Privacy instead: consent is the legal basis for ambient capture
    /// (`privacy.md` § 3.10(b)), and that card carries the disclosure this row
    /// has no room for.
    private func toggleAmbient() {
        if ambientOn {
            screenContext.setAmbientEnabled(false)
        } else {
            NotificationCenter.default.post(name: .nodOpenPrivacySettings, object: nil)
        }
    }

    private var ambientTint: Color {
        guard ambientOn else { return Theme.Palette.muted }
        return screenContext.needsAccessibility ? Theme.Palette.warning : Theme.Palette.success
    }

    private var ambientHelp: String {
        guard ambientOn else { return "Ambient context is off — open Settings › Privacy to turn it on" }
        if screenContext.needsAccessibility {
            return "Ambient context needs Accessibility access — grant it in Settings › Privacy"
        }
        return "Ambient context is on — Nod reads the window you're working in"
    }

    private var accountRow: some View {
        Button { onSelect(.settings) } label: {
            HStack(spacing: 9) {
                Image(systemName: "person.crop.circle")
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
