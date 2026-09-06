import AppKit
import SwiftUI

/// The main window: a labelled sidebar and the surface you're working in down
/// the middle.
///
/// A third column appears for one reason only — a session is open, and its chat
/// belongs beside it. Everything else is a surface you navigate to, including
/// what needs the user: a list of outstanding work standing permanently down the
/// side is what made a memory workspace read as an inbox.
struct MainWindowView: View {
    /// Session to open on first mount. Set when AppDelegate opens the window in
    /// response to a just-ended meeting.
    let initialFocusMeetingID: UUID?
    /// Settings, built by the composition root (it needs half the service
    /// graph) and rendered here as a centre surface — not a window of its own.
    let settings: AnyView

    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var analytics: ProductAnalytics
    @EnvironmentObject private var knowledgeStore: KnowledgeStore
    @EnvironmentObject private var labelStore: LabelStore
    @EnvironmentObject private var chatStore: ChatStore
    @EnvironmentObject private var knowledgeChat: KnowledgeChatStore
    @EnvironmentObject private var knowledgeThreads: KnowledgeThreadStore
    @EnvironmentObject private var integrations: IntegrationService
    @EnvironmentObject private var actionProposals: ActionProposalStore
    @EnvironmentObject private var hotkeys: HotkeyManager
    @EnvironmentObject private var settingsFocus: SettingsFocus
    @EnvironmentObject private var demoPlayback: DemoPlayback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var surface: Surface = .today
    /// Active project filter on the sessions list; nil shows every session.
    @State private var filterLabelID: UUID?
    @State private var undoToastID: UUID = .init()
    /// The session open *over* the current surface. The surface underneath is
    /// remembered, so closing returns to it.
    @State private var focus: Meeting?
    /// A beat report Today asked to open; cleared by any other navigation so
    /// the Beats row in the sidebar still opens the grid.
    @State private var beatRequest: BeatOpenRequest?
    @State private var confirmingClearChat = false
    @StateObject private var contextWidth = ContextColumnWidth()
    @State private var windowWidth: CGFloat = 1180

    /// What the centre column is showing when nothing is focused over it.
    enum Surface: String {
        /// What needs attention before anything is asked — the default, because
        /// a memory that waits to be queried reads as a chat with an archive.
        case today
        case chat
        case sessions
        /// Deleted sessions. A destination rather than a segment above the
        /// list: what you can do to a trashed session — restore it, destroy it
        /// — is not what you can do to a live one, so it is a different place,
        /// not a lens on the same one.
        case trash
        /// The questions that ask themselves. Its own destination rather than a
        /// section of Settings: a beat's answers are something you come here to
        /// read, not a preference you set once.
        case beats
        case settings
        case demoDailyModes
    }

    var body: some View {
        let contextW = contextWidth.width(for: focus?.id, totalWidth: windowWidth)
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                HomeSidebar(
                    surface: surface,
                    onSelect: { show($0) },
                    onNewChat: startNewChat,
                    onOpenProject: openProject,
                    onOpenThread: openThread,
                    onCapture: capture,
                    panelShortcut: hotkeys.combo(for: .togglePanel).displayString
                )
                centreColumn
                    .frame(maxWidth: .infinity)
                if showsContextColumn {
                    contextColumn(width: contextW)
                        .transition(.edgeSlide(.trailing, reduceMotion: reduceMotion))
                }
            }

            if showsContextColumn {
                ContextColumnDivider(
                    committedWidth: contextW,
                    windowWidth: windowWidth,
                    onCommit: { newWidth in
                        contextWidth.setWidth(newWidth, for: focus?.id, totalWidth: windowWidth)
                        contextWidth.commit()
                    },
                    onReset: { contextWidth.resetWidth(for: focus?.id) }
                )
            }
        }
        .animation(.standard(reduceMotion: reduceMotion), value: showsContextColumn)
        .readingWidth(into: $windowWidth)
        .tooltipContainer()
        .background(WindowBackdrop().ignoresSafeArea())
        .task {
            // Independent reads, and this now runs on every launch — serialising
            // them put three round trips in front of the first paint.
            async let meetings: Void = meetingStore.refresh()
            async let labels: Void = labelStore.refresh()
            async let threads: Void = knowledgeThreads.refreshIfNeeded()
            // Action items offer to file themselves in whatever is connected, so
            // every surface in this window needs to know what that is — not just
            // the two that happened to load it themselves.
            async let linked: Void = integrations.refreshIfNeeded()
            // What a meeting is offering to do outlives the session that
            // proposed it: approving happens minutes or days later, and until
            // this ran the review cards were only ever visible to the launch
            // that created them.
            async let proposals: Void = actionProposals.refresh()
            _ = await (meetings, labels, threads, linked, proposals)
            contextWidth.prune(keeping: Set(meetingStore.meetings.map(\.id)))
            if let id = initialFocusMeetingID {
                focus(on: id)
            }
            repairSearchIndex()
        }
        .onReceive(NotificationCenter.default.publisher(for: .nodOpenKnowledgeChats)) { _ in
            focus = nil
            surface = .chat
        }
        // `nod://action-items` outlives the screen it was named for. Released
        // builds, emails and the menu bar still send it, so it keeps working and
        // lands where the items now live: a meeting shows what it produced under
        // its own summary, and there is no longer a list of everything.
        .onReceive(NotificationCenter.default.publisher(for: .nodOpenActionItems)) { _ in
            focus = nil
            surface = .sessions
        }
        .onReceive(NotificationCenter.default.publisher(for: .nodOpenMeetingDetail)) { note in
            if let id = note.userInfo?[Notification.nodMeetingIDKey] as? UUID {
                focus(on: id)
            }
        }
        // A deep link asked for a Settings pane (post-checkout return, an upsell
        // button, the menu-bar item) — the pane itself reads which one.
        .onChange(of: settingsFocus.request) { request in
            guard request != nil else { return }
            show(.settings)
        }
        .onAppear {
            if settingsFocus.request != nil { surface = .settings }
        }
        .onChange(of: labelStore.labels) { labels in
            if let id = filterLabelID, !labels.contains(where: { $0.id == id }) {
                filterLabelID = nil
            }
        }
        .onChange(of: meetingStore.pendingUndo?.id) { newID in
            guard newID != nil else { return }
            let myID = UUID()
            undoToastID = myID
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await MainActor.run {
                    guard undoToastID == myID else { return }
                    if meetingStore.pendingUndo?.id == newID {
                        meetingStore.dismissUndo()
                    }
                }
            }
        }
        .onChange(of: focus?.id) { _ in confirmingClearChat = false }
    }

    /// The right column is now one thing only: the open session's chat. What
    /// needs the user is a screen you go to, not a panel that stands beside
    /// whatever you were doing — a memory workspace with a permanent list of
    /// outstanding work down its side is an inbox wearing a chat.
    private var showsContextColumn: Bool {
        focus != nil
    }

    /// An open session takes the centre edge to edge — the macOS split-view
    /// reading, where the detail replaces the list rather than floating over it.
    private var centreColumn: some View {
        ZStack(alignment: .bottom) {
            if let meeting = focus {
                MeetingDetailView(meeting: meeting, onClose: closeFocus)
                    .id(meeting.id)
                    .transition(.opacity)
                    .onExitCommand(perform: closeFocus)
            } else {
                surfaceContent
            }
            if let pending = meetingStore.pendingUndo {
                UndoToast(
                    message: "Moved to Trash",
                    onUndo: { Task { try? await meetingStore.restore(pending.id) } },
                    onDismiss: { meetingStore.dismissUndo() }
                )
                .padding(.bottom, 18)
                .transition(.edgeSlide(.bottom, reduceMotion: reduceMotion))
            }
        }
        .animation(.standard(reduceMotion: reduceMotion), value: focus?.id)
        .animation(.standard(reduceMotion: reduceMotion), value: surface)
        .animation(.momentum(reduceMotion: reduceMotion), value: meetingStore.pendingUndo?.id)
    }

    @ViewBuilder
    private var surfaceContent: some View {
        switch surface {
        case .today:
            TodayView(
                onCapture: capture,
                onOpenMeeting: { focus = $0 },
                onOpenReport: openReport,
                onAsk: askFromToday
            )
            .transition(.opacity)
        case .chat:
            chatHome.transition(.opacity)
        case .sessions, .trash:
            SessionsListView(
                mode: surface == .trash ? .trash : .all,
                filterLabelID: $filterLabelID,
                onOpen: { focus = $0 },
                onStartCapture: capture,
                onAskAboutProject: askAboutProject,
                panelShortcut: hotkeys.combo(for: .togglePanel).displayString
            )
            .transition(.opacity)
        case .beats:
            BeatsView(open: beatRequest, onOpenThread: openThread).transition(.opacity)
        case .settings:
            settings.transition(.opacity)
        case .demoDailyModes:
            // Only reachable from the sidebar row HomeSidebar shows while a
            // scenario is armed, so `armed` is never nil here in practice.
            if let scenario = demoPlayback.armed {
                DemoDailyModesView(scenario: scenario)
                    .transition(.opacity)
            }
        }
    }

    /// The cross-session chat, held to a reading width rather than stretched
    /// across the whole window — a composer 900pt wide is a worse composer.
    private var chatHome: some View {
        KnowledgeChatView(onOpenMeeting: openMeeting)
            .frame(maxWidth: Theme.Layout.editor)
            .frame(maxWidth: .infinity)
    }

    /// The open session's chat, beside the session itself — the question you'd
    /// ask about what's on screen, in the same place every time.
    @ViewBuilder private func contextColumn(width: CGFloat) -> some View {
        if let meeting = focus {
            VStack(spacing: 0) {
                sessionChatHeader(meeting)
                Divider().overlay(Theme.Palette.border)
                SessionChatView(meeting: meeting).id(meeting.id)
            }
            .frame(width: width)
            .background(Theme.Palette.overlay.opacity(0.025))
        }
    }

    private func sessionChatHeader(_ meeting: Meeting) -> some View {
        HStack(spacing: 9) {
            Image(meeting.kind.icon)
                .icon(13)
                .foregroundStyle(Theme.Palette.violet)
            VStack(alignment: .leading, spacing: 1) {
                Text("Ask about this session")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text(meeting.displayTitle(dateFormatter: Meeting.listDateFormatter))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if chatStore.openMeetingID == meeting.id, chatStore.loadState == .loaded, !chatStore.messages.isEmpty {
                clearChatControl(meetingID: meeting.id)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    @ViewBuilder
    private func clearChatControl(meetingID: UUID) -> some View {
        if confirmingClearChat {
            HStack(spacing: 6) {
                Text("Clear history?")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.danger)
                InlineConfirmButtons(
                    confirmIcon: "nc-scissors",
                    confirmHelp: "Clear history",
                    cancelHelp: "Keep history",
                    onConfirm: {
                        confirmingClearChat = false
                        Task { await chatStore.clearHistory(meetingID: meetingID) }
                    },
                    onCancel: { confirmingClearChat = false }
                )
            }
        } else {
            Button { confirmingClearChat = true } label: {
                Image("nc-scissors")
                    .icon(13)
                    .foregroundStyle(Theme.Palette.muted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Clear chat history")
        }
    }

    private func show(_ target: Surface) {
        guard surface != target || focus != nil || filterLabelID != nil else { return }
        // Sessions from the sidebar's own row means all of them; a project keeps
        // its filter because `openProject` sets it after this.
        if target == .sessions { filterLabelID = nil }
        surface = target
        focus = nil
        beatRequest = nil
    }

    private func openReport(_ row: TodayView.BeatReportRow) {
        show(.beats)
        beatRequest = BeatOpenRequest(beat: row.beat, runID: row.run.id)
    }

    /// Open a session over whatever is in the centre. The context column
    /// follows it to that session's chat.
    private func openMeeting(_ id: UUID) {
        guard let meeting = meetingStore.meetings.first(where: { $0.id == id }) else { return }
        focus = meeting
    }

    private func closeFocus() {
        focus = nil
    }

    /// Everything Nod knows about this project becomes the scope of the next
    /// question. The list stays where it was — the user is leaving it, not
    /// filtering it further.
    private func askAboutProject(_ label: SessionLabel) {
        knowledgeChat.pendingDraft = "\(MentionMark(project: label).token) "
        show(.chat)
    }

    /// A question typed on Today lands in the chat mid-flight: the composer
    /// there is the real one, this only saves retyping the thought.
    private func askFromToday(_ request: ActionDelegation.AskRequest) {
        if request.session != nil {
            analytics.record(.actionItemActed, properties: .init(surface: .home, outcome: .asked))
        }
        // A fresh thread: a question raised from Today is its own subject,
        // not a continuation of whatever chat happened to be open last.
        knowledgeChat.startNewThread()
        knowledgeChat.pendingMentions = request.session.map { [$0] } ?? []
        knowledgeChat.pendingDraft = request.text
        show(.chat)
    }

    private func openProject(_ label: SessionLabel) {
        surface = .sessions
        focus = nil
        filterLabelID = label.id
    }

    private func startNewChat() {
        knowledgeChat.startNewThread()
        show(.chat)
    }

    /// Ask for a capture. The window coordinator owns the notch and its session,
    /// so it decides what "capture" means from here.
    private func capture() {
        NotificationCenter.default.post(name: .nodShowPanel, object: nil)
    }

    private func openThread(_ id: UUID) {
        focus = nil
        surface = .chat
        Task { await knowledgeChat.open(threadID: id) }
    }

    /// Give the search index a chance to catch up on sessions an interrupted
    /// indexing run left behind. Detached from the launch `task` and throttled
    /// inside the store, so it never sits in front of the first paint.
    private func repairSearchIndex() {
        Task(priority: .background) {
            await knowledgeStore.repairUnderIndexed { id in
                let records = try await meetingStore.fetchTranscript(meetingID: id)
                return records.promptContext(names: meetingStore.byID[id]?.speakerNames)
            }
        }
    }

    /// Open the matching session from the in-memory cache. No-op if the id
    /// isn't cached — the caller inserts into MeetingStore before signalling.
    private func focus(on id: UUID) {
        guard let meeting = meetingStore.meetings.first(where: { $0.id == id }) else {
            Log.ui.info("MainWindowView.focus skipped — meeting not in cache: \(id.uuidString)")
            return
        }
        focus = meeting
    }
}

private struct UndoToast: View {
    let message: String
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image("nc-trash")
                .icon(12)
                .foregroundStyle(Theme.Palette.muted)
            Text(message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 8)
            GlassPillButton("Undo", size: .compact, action: onUndo)
            Button(action: onDismiss) {
                Image("nc-xmark")
                    .icon(9)
                    .foregroundColor(Theme.Palette.muted)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Theme.Palette.overlay.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 380)
        .background(
            Capsule(style: .continuous)
                .glassFill()
                .overlay(Capsule().fill(Theme.Palette.bgSoft.opacity(0.85)))
                .overlay(Capsule().stroke(Theme.Palette.borderStrong, lineWidth: 0.5))
        )
        .shadow(color: DesignTokens.Shadow.ink(light: 0.16, dark: 0.35), radius: 14, x: 0, y: 6)
    }
}

/// The context column's divider: the visible seam, the invisible grab strip,
/// and the in-flight resize preview — all owned here so a drag mutates only this
/// view's state, never the sibling panes.
private struct ContextColumnDivider: View {
    let committedWidth: CGFloat
    let windowWidth: CGFloat
    let onCommit: (CGFloat) -> Void
    let onReset: () -> Void

    @State private var preview: CGFloat?
    @State private var lastTranslation: CGFloat = 0
    @State private var hovering = false
    @State private var dragging = false
    @State private var cursorPushed = false

    private var active: Bool {
        hovering || dragging
    }

    private var width: CGFloat {
        preview ?? committedWidth
    }

    var body: some View {
        let thickness: CGFloat = active ? 2 : 0.5
        let seamColor = active ? Theme.Palette.violet.opacity(0.7) : Theme.Palette.border
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(seamColor)
                .frame(width: thickness)
                .frame(maxHeight: .infinity)
                .offset(x: max(0, windowWidth - width - thickness / 2))
                .ignoresSafeArea(.container, edges: .top)
                .allowsHitTesting(false)

            Color.clear
                .frame(width: ContextColumnWidth.handleWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .offset(x: max(0, windowWidth - width - ContextColumnWidth.handleWidth / 2))
                .onHover { hovering in
                    self.hovering = hovering
                    syncCursor()
                }
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            dragging = true
                            let delta = value.translation.width - lastTranslation
                            lastTranslation = value.translation.width
                            preview = ContextColumnWidth.clampedWidth(width - delta, totalWidth: windowWidth)
                            syncCursor()
                        }
                        .onEnded { _ in
                            lastTranslation = 0
                            dragging = false
                            if let preview {
                                onCommit(preview)
                            }
                            preview = nil
                            syncCursor()
                        }
                )
                .onTapGesture(count: 2) {
                    onReset()
                    preview = nil
                }
                .onDisappear {
                    hovering = false
                    dragging = false
                    syncCursor()
                }
                .help("Drag to resize · double-click to reset")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Keep exactly one resize cursor pushed while hovering or dragging, and pop
    /// it otherwise — guarded so the global cursor stack can't drift.
    private func syncCursor() {
        if active, !cursorPushed {
            NSCursor.resizeLeftRight.push()
            cursorPushed = true
        } else if !active, cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}
