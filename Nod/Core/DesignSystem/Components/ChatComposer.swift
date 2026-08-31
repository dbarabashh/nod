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

    /// Identity for the highlight, so the row being drawn and the row Return
    /// would take are compared by the same thing.
    var id: String {
        switch self {
        case let .project(project): "project:\(project.id)"
        case let .session(session): "session:\(session.id)"
        case let .tool(tool): "tool:\(tool.rawValue)"
        case .connectTool: "connect"
        }
    }
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
    /// Which row Return would take. Reset whenever the query changes, because
    /// the list under it has changed with it.
    @State private var highlighted = 0

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
                    search: query,
                    highlighted: highlighted
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
                    keys: steer,
                    onSend: onSend
                )
                // A word-boundary "/" or "@" opens the panel, and *stays in the
                // text*: what follows it is the query, typed in this field with
                // the caret where it already was. Mid-word both stay literal,
                // so an email, a handle, a path and a date are typed as they
                // are.
                .onChange(of: text) { value in
                    withAnimation(.standard(reduceMotion: reduceMotion)) { retrigger(on: value) }
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

    /// The run being typed after the trigger, or nil when nothing is open.
    ///
    /// Derived rather than stored: the field is free to change under us —
    /// undo, a paste, a click that moves the caret — and a second copy of this
    /// would be wrong every time it did.
    private var query: String {
        guard let trigger, let start = text.lastIndex(of: trigger.rawValue) else { return "" }
        return String(text[text.index(after: start)...])
    }

    /// Opens, closes and re-queries the panel from whatever the field now says.
    private func retrigger(on value: String) {
        if let trigger {
            guard let start = value.lastIndex(of: trigger.rawValue) else { return close() }
            // A space ends a mention: past it the person is writing a sentence
            // again, not choosing from a list.
            guard !value[value.index(after: start)...].contains(" ") else { return close() }
            highlighted = 0
            return
        }
        guard let last = value.last, let typed = ChatComposerTrigger(rawValue: last),
              MentionMark.standsAlone(after: value.dropLast().last)
        else { return }
        highlighted = 0
        trigger = typed
    }

    /// The panel's keyboard, borrowed from the field. Returns false when
    /// nothing is open, which is how Return goes back to sending.
    private func steer(_ key: ComposerKey) -> Bool {
        guard trigger != nil else { return false }
        let count = visiblePicks.count
        switch key {
        case .up:
            guard count > 0 else { return true }
            highlighted = (highlighted - 1 + count) % count
        case .down:
            guard count > 0 else { return true }
            highlighted = (highlighted + 1) % count
        case .commit:
            guard visiblePicks.indices.contains(highlighted) else { return false }
            pick(visiblePicks[highlighted])
        case .dismiss:
            close()
            isFocused = true
        }
        return true
    }

    /// What the panel is showing, in its drawn order. Held here as well as
    /// drawn there because Return has to resolve without asking a view.
    private var visiblePicks: [ChatMentionPick] {
        guard let trigger else { return [] }
        return ChatMentionPicker.picks(
            projects: trigger.listsProjects ? ChatMentionPicker.projects(sources.projects, matching: query) : [],
            sessions: ChatMentionPicker.sessions(sources.sessions, matching: query),
            tools: sources.tools ? ChatMentionPicker.tools(matching: query) : []
        )
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

    /// Writes the token over the `@query` that summoned it, so the trigger and
    /// the half-typed name are replaced by the pill rather than left beside it.
    private func append(_ mark: MentionMark) {
        if let trigger, let start = text.lastIndex(of: trigger.rawValue) {
            text.removeSubrange(start...)
        }
        mark.insert(into: &text)
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
    /// What has been typed after the trigger, and which row is selected. Both
    /// live in the composer: the caret never leaves the field, so the field is
    /// the only thing that knows either.
    let search: String
    let highlighted: Int

    @EnvironmentObject private var integrations: IntegrationService
    @EnvironmentObject private var catalogue: IntegrationCatalogue

    private var matchingProjects: [SessionLabel] {
        guard trigger.listsProjects else { return [] }
        return Self.projects(sources.projects, matching: search)
    }

    /// The three filters, shared with the composer: it has to resolve what
    /// Return would take without asking a view, and two copies of "what is
    /// showing" would disagree the moment either was edited.
    static func projects(_ projects: [SessionLabel], matching search: String) -> [SessionLabel] {
        guard !search.isEmpty else { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    static func sessions(_ sessions: [Meeting], matching search: String) -> [Meeting] {
        guard !search.isEmpty else { return Array(sessions.prefix(8)) }
        return Array(sessions.lazy.filter { $0.matches(search) }.prefix(8))
    }

    static func tools(matching search: String) -> [IntegrationProvider] {
        guard !search.isEmpty else { return IntegrationProvider.allCases }
        return IntegrationProvider.allCases.filter { $0.displayName.localizedCaseInsensitiveContains(search) }
    }

    /// Lazily, and capped at what is drawn. Eagerly filtering meant lowercasing
    /// every session's summary — the whole store — on every keystroke, three
    /// times over, to render eight rows.
    private var matchingSessions: [Meeting] {
        Self.sessions(sources.sessions, matching: search)
    }

    private var matchingTools: [IntegrationProvider] {
        guard sources.tools else { return [] }
        return Self.tools(matching: search)
    }

    /// Products this account authorized that Nod has no actions for yet.
    ///
    /// Listed rather than hidden: somebody who has just connected one and does
    /// not find it here concludes the connection failed. Listed as what it is,
    /// though — it cannot be mentioned, because there is nothing behind the
    /// mention.
    private var matchingApps: [CatalogueApp] {
        guard sources.tools else { return [] }
        let apps = catalogue.apps(for: integrations.linkedApps)
        guard !search.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        // Each list evaluated once per pass, not three times: `isEmpty`, the
        // section guard and the `ForEach` each used to re-run the filter.
        let projects = matchingProjects
        let sessions = matchingSessions
        let tools = matchingTools
        let apps = matchingApps
        let selected = Self.picks(projects: projects, sessions: sessions, tools: tools)
            .indices.contains(highlighted)
            ? Self.picks(projects: projects, sessions: sessions, tools: tools)[highlighted].id
            : nil
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if projects.isEmpty, sessions.isEmpty, tools.isEmpty, apps.isEmpty {
                        Text(search.isEmpty ? "Nothing to mention yet" : "Nothing matches “\(search)”")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Palette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 10)
                    }
                    // Tools lead: they are the thing the trigger is reached for
                    // most, and the thing the person has just named half of.
                    section("Tools", items: tools) { toolRow($0, selected: selected) }
                    section("Sessions", items: sessions) { sessionRow($0, selected: selected) }
                    section("Projects", items: projects) { projectRow($0, selected: selected) }
                    section("Connected", items: apps, row: appRow)
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
    }

    /// Everything selectable, in the order it is drawn — the list the composer
    /// steps through and takes from. Built here rather than in the composer so
    /// what Return picks and what the eye is on cannot come apart.
    static func picks(
        projects: [SessionLabel],
        sessions: [Meeting],
        tools: [IntegrationProvider]
    ) -> [ChatMentionPick] {
        tools.map { .tool($0) } + sessions.map { .session($0) } + projects.map { .project($0) }
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

    private func projectRow(_ project: SessionLabel, selected: String?) -> some View {
        row(action: { onPick(.project(project)) }, isSelected: ChatMentionPick.project(project).id == selected, content: {
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

    private func sessionRow(_ session: Meeting, selected: String?) -> some View {
        row(action: { onPick(.session(session)) }, isSelected: ChatMentionPick.session(session).id == selected, content: {
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
    ///
    /// A tool the organization switched off is a third state, not the same as
    /// an unconnected one: the person may well have connected it, Settings says
    /// so, and offering "Connect" here sends them through an authorization that
    /// changes nothing and leaves the row exactly as it was.
    private func toolRow(_ tool: IntegrationProvider, selected: String?) -> some View {
        let isBlocked = integrations.blockedByOrganization.contains(tool)
        let isUsable = !isBlocked && integrations.linked.contains(tool)
        let note = isBlocked ? "Off for your organization" : (isUsable ? nil : "Connect")
        return row(
            action: isBlocked ? nil : { onPick(isUsable ? .tool(tool) : .connectTool) },
            isSelected: ChatMentionPick.tool(tool).id == selected
        ) {
            ProviderMark(provider: tool, size: 14)
                .frame(width: 16)
                .opacity(isUsable ? 1 : 0.45)
            Text(tool.displayName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isUsable ? Theme.Palette.ink : Theme.Palette.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let note {
                Text(note)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
            }
        }
    }

    /// An authorized product with nothing behind it yet. Not a button: there is
    /// no mention to insert, and a row that answered a click by doing nothing
    /// would be worse than one that plainly says why.
    private func appRow(_ app: CatalogueApp) -> some View {
        HStack(spacing: 8) {
            CatalogueMark(slug: app.slug, size: 14)
                .frame(width: 16)
                .opacity(0.45)
            Text(app.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.Palette.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("No actions yet")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.muted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    /// A panel row. `action` is nil for a row that states something rather than
    /// offering it — a button that answered a click by doing nothing would be
    /// worse than one that plainly says why.
    @ViewBuilder
    private func row(
        action: (() -> Void)?,
        isSelected: Bool = false,
        @ViewBuilder content: () -> some View
    ) -> some View {
        let body = HStack(spacing: 9) { content() }
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            // `surfaceStrong`, not `overlay`: the latter is `themed(light:
            // .black, dark: .white)` at full opacity — a wash to be given an
            // opacity, not a fill. Used raw it painted a black bar on the Light
            // theme and swallowed the label sitting on it.
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Theme.Palette.surfaceStrong : .clear)
            )
            .contentShape(Rectangle())
        if let action {
            Button(action: action) { body }
                .buttonStyle(.plain)
                .linkCursor()
        } else {
            body
        }
    }
}

/// The tools Nod can already act in, stated under the composer.
///
/// Passive discovery: somebody who never types `@` still learns that Linear and
/// the calendar are reachable, which is the whole argument for having connected
/// them.
///
/// Passive is the default and not the only mode. On a surface with no room for
/// a mention picker — the notch's Ask box — the same marks are how a product
/// gets named at all, so they take a tap and show which one the sentence is
/// aimed at. Two rows would have drifted: the second one was written without
/// the dimmed authorized-but-not-yet-actionable marks, which is precisely the
/// "reads as a connection that failed" case this row exists to prevent.
struct ConnectedToolsRow: View {
    /// The products the sentence being written names, drawn as aimed. Empty is
    /// the ordinary case — a row that states what is connected and nothing more.
    var aimed: Set<IntegrationProvider> = []
    /// Tapping a mark. Nil leaves the row passive, which is what a surface with
    /// its own mention picker wants.
    var onTap: ((IntegrationProvider) -> Void)?

    @EnvironmentObject private var integrations: IntegrationService
    @EnvironmentObject private var catalogue: IntegrationCatalogue

    private var linked: [IntegrationProvider] {
        integrations.usable
    }

    /// Authorized, but with no actions behind it. Dimmed rather than absent —
    /// this row is what tells somebody a connection took, and a product missing
    /// from it reads as a connection that failed.
    private var authorized: [CatalogueApp] {
        catalogue.apps(for: integrations.linkedApps)
    }

    var body: some View {
        // Read once: `isEmpty`, the `ForEach` and the accessibility label each
        // used to re-run the filter, on a row that re-renders with every word
        // of a streaming answer.
        let linked = linked
        let authorized = authorized
        if !linked.isEmpty || !authorized.isEmpty {
            HStack(spacing: 5) {
                ForEach(linked) { provider in
                    mark(provider)
                }
                ForEach(authorized) { app in
                    CatalogueMark(slug: app.slug, size: 13)
                        .opacity(0.45)
                        // The same inset a tappable mark carries. Without it
                        // these sit at a different pitch from the neighbours
                        // they share a row with.
                        .padding(onTap == nil ? 0 : 4)
                        .glyphTooltip("\(app.name) is connected — Nod can't act in it yet")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "Connected tools: \((linked.map(\.displayName) + authorized.map(\.name)).joined(separator: ", "))"
            )
            // Naming an authorized product needs the catalogue, and Settings is
            // not the only place one shows up. Asked here rather than wired
            // through the service: this is the surface that needs the answer,
            // and `resolve` already skips what it holds.
            .task(id: integrations.linkedApps) {
                await catalogue.resolve(integrations.linkedApps)
            }
        }
    }

    /// A mark that offers something, or one that merely states it — the same
    /// split `ChatMentionPicker.row(action:)` makes, and for the same reason: a
    /// button that answers a click by doing nothing is worse than a glyph that
    /// plainly isn't one.
    ///
    /// `glyphTooltip` rather than `help`: AppKit's tooltip needs the window to
    /// take key focus, and the notch panel deliberately never does.
    @ViewBuilder
    private func mark(_ provider: IntegrationProvider) -> some View {
        let glyph = ProviderMark(provider: provider, size: 13)
        if let onTap {
            let isAimed = aimed.contains(provider)
            Button { onTap(provider) } label: {
                glyph
                    .opacity(isAimed ? 1 : 0.5)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                            .fill(isAimed ? Theme.Palette.surfaceStrong : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .linkCursor()
            .glyphTooltip(isAimed ? "Asking \(provider.displayName)" : "Ask \(provider.displayName)")
        } else {
            glyph.glyphTooltip("\(provider.displayName) is connected — mention it with @")
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

    /// Which products a sentence names. One definition, because the pill a
    /// person sees, the mark shown as aimed at, and the tools the question is
    /// allowed to reach have to be the same answer — asked separately, a
    /// question that read "@Linear" was routed into Slack.
    static func namedTools(in text: String) -> [IntegrationProvider] {
        named(in: text, from: IntegrationProvider.allCases, mark: MentionMark.init(tool:))
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
