import AppKit
import SwiftUI

/// What opened the panel, and so what it offers.
///
/// `/` is the way in to everything the question can be pointed at; `@` is the
/// narrower habit borrowed from every other composer — naming a thing that
/// already exists. Projects are a scope rather than a thing to name, so they
/// answer to the slash alone.
enum ChatComposerTrigger: Character {
    case slash = "/"
    case at = "@"

    var listsProjects: Bool {
        self == .slash
    }
}

/// What a chat surface can be pointed at.
///
/// A surface offers a kind only when its answer can actually reach it: the
/// panel is a promise, and a chat that lists projects it cannot scope to has
/// made one it doesn't keep. Ask Nod fills all three; the per-session chat
/// fills sessions and tools, having no scope to narrow.
struct ChatMentionSources {
    var projects: [SessionLabel] = []
    var sessions: [Meeting] = []
    var tools = false
}

/// What somebody chose from the panel. The composer writes the token itself —
/// this is the surface's chance to record what the token now means to it.
enum ChatMentionPick {
    case project(SessionLabel)
    case session(Meeting)
    case tool(IntegrationProvider)
    /// An unconnected tool. Nothing is written; the surface takes them to
    /// settings.
    case connectTool
}

/// The chat composer: a mention panel, the field, and the send button.
///
/// One composer for both threads. They differ in what a mention can reach and
/// in what they do with a pick — not in how a question gets written, which is
/// why the triggers, the token the pick inserts, and the panel's chrome live
/// here rather than in each surface's copy of them.
struct ChatComposer: View {
    let prompt: String
    @Binding var text: String
    @Binding var isFocused: Bool
    var isEnabled = true
    let canSend: Bool
    /// A turn is running. The field stays live through it — on a desktop the
    /// keyboard is always to hand, and a disabled composer throws away what
    /// somebody typed while they waited — and the send button becomes Stop.
    var isGenerating = false
    var onStop: () -> Void = {}
    let sources: ChatMentionSources
    /// The names already in the draft, drawn as pills.
    let mentions: [MentionMark]
    /// What a pick means to this surface. The token itself is written here.
    let onPick: (ChatMentionPick) -> Void
    let onSend: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Which trigger opened the panel, or nil while it is closed — the two
    /// facts are one, and as a flag beside a mode they could disagree.
    @State private var trigger: ChatComposerTrigger?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Inside the surface rather than floating over it: a popover of its
            // own width, with its own arrow and its own material, read as a
            // system menu that happened to appear near the composer. This is
            // part of the question being written, so it wears the composer's
            // width and the composer's chrome and grows the block upward.
            if let trigger {
                ChatMentionPicker(
                    trigger: trigger,
                    sources: sources,
                    onPick: pick,
                    onDismiss: {
                        close()
                        isFocused = true
                    }
                )
                Divider().overlay(Theme.Palette.border)
                    .transition(.opacity)
            }
            HStack(alignment: .center, spacing: 8) {
                ChatComposerField(
                    prompt: prompt,
                    text: $text,
                    isEnabled: isEnabled,
                    isFocused: $isFocused,
                    mentions: mentions,
                    onSend: onSend
                )
                // A word-boundary "/" or "@" opens the panel (and is consumed —
                // what gets chosen is re-inserted as "@Name" inline). Mid-word
                // both stay literal, so an email, a handle, a path and a date
                // are typed as they are.
                .onChange(of: text) { value in
                    guard let last = value.last, let typed = ChatComposerTrigger(rawValue: last) else { return }
                    let preceding = value.dropLast().last
                    let atWordBoundary = preceding == nil || preceding == " " || preceding == "\n"
                    guard atWordBoundary else { return }
                    text.removeLast()
                    withAnimation(.standard(reduceMotion: reduceMotion)) { trigger = typed }
                }

                if isGenerating {
                    stopButton
                } else {
                    sendButton
                }
            }
        }
        .animation(.standard(reduceMotion: reduceMotion), value: isGenerating)
    }

    private var sendButton: some View {
        Button(action: onSend) {
            Image("nc-circle-arrow-up")
                .icon(13)
                .foregroundStyle(canSend ? Theme.GlassButton.text : .white)
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(canSend ? AnyShapeStyle(Theme.GlassButton.fill) : AnyShapeStyle(Theme.Palette.muted.opacity(0.4)))
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
    }

    /// Words, not a glyph. Every desktop chat that has room for the label uses
    /// it, an icon-only square reads as "record" as readily as "stop", and Nod
    /// ships no stop glyph — a Nucleo gap is not a reason to invent one when
    /// the better control on this platform is text anyway.
    private var stopButton: some View {
        Button(action: onStop) {
            Text("Stop")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.GlassButton.text)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule(style: .continuous).fill(Theme.GlassButton.fill))
        }
        .buttonStyle(.plain)
        .help("Stop generating (Esc)")
        .keyboardShortcut(.cancelAction)
    }

    private func pick(_ pick: ChatMentionPick) {
        switch pick {
        case let .project(project): append(MentionMark(project: project))
        case let .session(session): append(MentionMark(session: session))
        case let .tool(tool): append(MentionMark(tool: tool))
        case .connectTool: close()
        }
        onPick(pick)
    }

    private func append(_ mark: MentionMark) {
        if !text.isEmpty, !text.hasSuffix(" ") { text += " " }
        text += "\(mark.token) "
        close()
        isFocused = true
    }

    private func close() {
        withAnimation(.standard(reduceMotion: reduceMotion)) { trigger = nil }
    }
}

/// What the composer's triggers can reach: a project, a session, or a tool Nod
/// can act in.
///
/// It used to list sessions alone, while projects were narrowed by a separate
/// pill beside the composer — two mechanisms for one job, and no way to say
/// "in this project, check that tool" in a single sentence. One list, three
/// kinds, and every pick lands in the text as a token.
struct ChatMentionPicker: View {
    let trigger: ChatComposerTrigger
    let sources: ChatMentionSources
    let onPick: (ChatMentionPick) -> Void
    let onDismiss: () -> Void

    @EnvironmentObject private var integrations: IntegrationService
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var escape: Any?

    private static let escapeKey: UInt16 = 53

    private var matchingProjects: [SessionLabel] {
        guard trigger.listsProjects else { return [] }
        guard !search.isEmpty else { return sources.projects }
        return sources.projects.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    /// Lazily, and capped at what is drawn. Eagerly filtering meant lowercasing
    /// every session's summary — the whole store — on every keystroke, three
    /// times over, to render eight rows.
    private var matchingSessions: [Meeting] {
        guard !search.isEmpty else { return Array(sources.sessions.prefix(8)) }
        return Array(sources.sessions.lazy.filter { $0.matches(search) }.prefix(8))
    }

    private var matchingTools: [IntegrationProvider] {
        guard sources.tools else { return [] }
        guard !search.isEmpty else { return IntegrationProvider.allCases }
        return IntegrationProvider.allCases.filter { $0.displayName.localizedCaseInsensitiveContains(search) }
    }

    /// Names what is actually listed, so the panel never invites a search for
    /// something this chat cannot reach.
    private var searchPrompt: String {
        let kinds = [
            trigger.listsProjects && !sources.projects.isEmpty ? "projects" : nil,
            sources.sessions.isEmpty ? nil : "sessions",
            sources.tools ? "tools" : nil
        ].compactMap { $0 }
        guard let last = kinds.last else { return "Search" }
        guard kinds.count > 1 else { return "Search \(last)" }
        return "Search \(kinds.dropLast().joined(separator: ", ")) and \(last)"
    }

    var body: some View {
        // Each list evaluated once per pass, not three times: `isEmpty`, the
        // section guard and the `ForEach` each used to re-run the filter.
        let projects = matchingProjects
        let sessions = matchingSessions
        let tools = matchingTools
        return VStack(alignment: .leading, spacing: 0) {
            searchField
            Divider().overlay(Theme.Palette.border)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if projects.isEmpty, sessions.isEmpty, tools.isEmpty {
                        Text("Nothing matches “\(search)”")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Palette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 10)
                    }
                    section("Projects", items: projects, row: projectRow)
                    section("Sessions", items: sessions, row: sessionRow)
                    section("Tools", items: tools, row: toolRow)
                }
                .padding(.bottom, 4)
            }
            // Sized to its rows up to a ceiling, not pinned to it: two results
            // in a 300pt box is mostly empty box.
            .frame(maxHeight: 260)
        }
        .frame(maxWidth: .infinity)
        // Grows out of the top of the field rather than appearing whole: the
        // panel is part of the composer, and a block that pops into place reads
        // as a different surface arriving.
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear {
            searchFocused = true
            watchForEscape()
        }
        .onDisappear(perform: stopWatchingForEscape)
    }

    /// Escape, heard by the panel itself.
    ///
    /// `onExitCommand` never fired: the search field takes focus the moment the
    /// panel opens, and its field editor handles the key and stops it there —
    /// so the responder chain the modifier listens on never sees it, and the
    /// panel had no way out but picking something.
    private func watchForEscape() {
        stopWatchingForEscape()
        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == Self.escapeKey else { return event }
            onDismiss()
            return nil
        }
    }

    private func stopWatchingForEscape() {
        guard let escape else { return }
        NSEvent.removeMonitor(escape)
        self.escape = nil
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image("nc-magnifier")
                .icon(11)
                .foregroundStyle(Theme.Palette.muted)
            TextField(searchPrompt, text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.ink)
                .focused($searchFocused)
            Button(action: onDismiss) {
                Image("nc-xmark")
                    .icon(10)
                    .foregroundStyle(Theme.Palette.muted)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .linkCursor()
            .help("Close")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        // The row is as tall as its own text. Left free it takes a share of any
        // height the panel is given, and a field editor draws its line at the
        // top of the box it was handed — so the text climbed away from the
        // magnifier beside it, which stayed in the middle.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Takes the items rather than a flag about them, so the heading and the
    /// rows can never disagree about whether the section has anything in it.
    @ViewBuilder
    private func section<Item: Identifiable>(
        _ title: String,
        items: [Item],
        @ViewBuilder row: @escaping (Item) -> some View
    ) -> some View {
        if !items.isEmpty {
            SectionLabel(title)
                .padding(.horizontal, 6)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ForEach(items) { row($0) }
        }
    }

    private func projectRow(_ project: SessionLabel) -> some View {
        row(action: { onPick(.project(project)) }, content: {
            Circle()
                .fill(project.swatchColor)
                .frame(width: 8, height: 8)
                .frame(width: 16)
            Text(project.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
        })
    }

    private func sessionRow(_ session: Meeting) -> some View {
        row(action: { onPick(.session(session)) }, content: {
            Image(session.kind.icon)
                .icon(11)
                .foregroundStyle(Theme.Palette.muted)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle(dateFormatter: Meeting.shortDateFormatter))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                Text(Meeting.shortDateFormatter.string(from: session.startedAt))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.Palette.muted)
            }
            Spacer(minLength: 0)
        })
    }

    /// Every tool is listed, connected or not. Hiding the unconnected ones
    /// would answer "what can Nod reach?" with a list that depends on what you
    /// happened to set up months ago — so an unlinked tool stays visible and
    /// offers the one thing that would make it work.
    private func toolRow(_ tool: IntegrationProvider) -> some View {
        let isLinked = integrations.isUsable(tool)
        return row(action: { onPick(isLinked ? .tool(tool) : .connectTool) }, content: {
            ProviderMark(provider: tool, size: 14)
                .frame(width: 16)
                .opacity(isLinked ? 1 : 0.45)
            Text(tool.displayName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isLinked ? Theme.Palette.ink : Theme.Palette.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
            if !isLinked {
                Text("Connect")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
            }
        })
    }

    private func row(action: @escaping () -> Void, @ViewBuilder content: () -> some View) -> some View {
        Button(action: action) {
            HStack(spacing: 9) { content() }
                .padding(.horizontal, 6)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
    }
}

/// The tools Nod can already act in, stated under the composer.
///
/// Passive discovery: somebody who never types `@` still learns that Linear and
/// the calendar are reachable, which is the whole argument for having connected
/// them.
struct ConnectedToolsRow: View {
    @EnvironmentObject private var integrations: IntegrationService

    private var linked: [IntegrationProvider] {
        IntegrationProvider.allCases.filter(integrations.isUsable)
    }

    var body: some View {
        // Read once: `isEmpty`, the `ForEach` and the accessibility label each
        // used to re-run the filter, on a row that re-renders with every word
        // of a streaming answer.
        let linked = linked
        if !linked.isEmpty {
            HStack(spacing: 5) {
                ForEach(linked) { provider in
                    ProviderMark(provider: provider, size: 13)
                        .help("\(provider.displayName) is connected — mention it with @")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Connected tools: \(linked.map(\.displayName).joined(separator: ", "))")
        }
    }
}

/// The kinds turned into the mark that draws them, in one place. Built once per
/// surface, the copies drifted the moment a glyph changed and a pill in the
/// transcript stopped matching the pill the person had been looking at.
extension MentionMark {
    init(project: SessionLabel) {
        self.init(name: project.name, glyph: .dot(NSColor(project.swatchColor)))
    }

    init(tool: IntegrationProvider) {
        self.init(name: tool.displayName, glyph: .icon(tool.iconName))
    }

    init(session: Meeting, opens: Bool = false) {
        self.init(
            id: session.id,
            title: session.displayTitle(dateFormatter: Meeting.shortDateFormatter),
            opens: opens
        )
    }

    /// `opens` is the sent message, where the pill goes to its session. In the
    /// composer the question is still being written and the pill is inert.
    init(session: KnowledgeChatStore.SessionRef, opens: Bool = false) {
        self.init(id: session.id, title: session.title, opens: opens)
    }

    private init(id: UUID, title: String, opens: Bool) {
        self.init(
            name: title,
            glyph: .icon("nc-layers-3"),
            url: opens ? URL(string: "nod-meeting://m/\(id.uuidString)") : nil
        )
    }
}
