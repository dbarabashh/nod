import SwiftUI

/// The quick panel's content: one field that searches every session, and — on
/// a "?" prefix or Tab — asks across all of them instead. Search is instant and
/// local-first; asking is the deliberate, slower path, so the two share a field
/// but never a keystroke's meaning.
struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @EnvironmentObject private var chat: KnowledgeChatStore
    @EnvironmentObject private var entitlements: EntitlementService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onOpenMeeting: (UUID) -> Void
    let onAsk: () -> Void
    let onContinueInLibrary: () -> Void
    let onDismiss: () -> Void

    @FocusState private var fieldFocused: Bool

    /// Matches the panel's own pill radius family rather than a window's.
    private static let radius = Theme.Radii.card

    var body: some View {
        VStack(spacing: 0) {
            field
            if model.isAnswering {
                askPane
            } else if !model.rows.isEmpty {
                Divider().overlay(Theme.Palette.border)
                resultList
            }
            Divider().overlay(Theme.Palette.border)
            footer
        }
        // The panel's own glass, not SwiftUI's: `.ultraThinMaterial` blends
        // within-window and renders as a black slab on a borderless
        // non-activating panel, which has nothing of its own to sample. The
        // radius goes to the material itself, since SwiftUI can't clip it.
        //
        // No padding and no SwiftUI shadow: the window is exactly this card, so
        // depth comes from the window's own shadow instead of a transparent
        // margin that the blur was visibly spilling into.
        .background(PanelMaterial.card(cornerRadius: Self.radius))
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .stroke(Theme.Palette.borderStrong, lineWidth: 0.5)
        )
        .onAppear { fieldFocused = true }
    }

    // MARK: - Field

    private var field: some View {
        HStack(spacing: 10) {
            Image(model.isAnswering ? "nc-sparkle-3" : "nc-magnifier")
                .icon(15)
                .foregroundStyle(model.isAnswering ? Theme.Palette.ink : Theme.Palette.muted)
                .frame(width: 18)
            TextField("Search or ask across your sessions", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(Theme.Palette.ink)
                .focused($fieldFocused)

            if model.isAnswering {
                modeChip
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        // Progress lives on the field's edge rather than as a spinner beside
        // the text: it reads as "still working" without adding a second moving
        // thing next to what the user is trying to read.
        .overlay(alignment: .bottom) { SearchProgressLine(isActive: model.isSearching) }
    }

    private var modeChip: some View {
        HStack(spacing: 4) {
            Image("nc-sparkle-3")
                .icon(8.5)
            Text("Ask Nod")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(Theme.Palette.ink.opacity(0.8))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.Palette.surfaceStrong)
                .overlay(Capsule().stroke(Theme.Palette.border, lineWidth: 0.5))
        )
    }

    // MARK: - Results

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, isSelected: index == model.selection)
                            .id(row.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 320)
            .tooltipContainer()
            .onChange(of: model.selection) { index in
                guard model.rows.indices.contains(index) else { return }
                withAnimation(.standard(reduceMotion: reduceMotion)) {
                    proxy.scrollTo(model.rows[index].id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: LauncherModel.Row, isSelected: Bool) -> some View {
        switch row {
        case let .ask(question):
            askRow(question, isSelected: isSelected)
                .onTapGesture { onAsk() }
        case let .session(result):
            resultRow(result, isSelected: isSelected)
                .onTapGesture { onOpenMeeting(result.id) }
        }
    }

    /// Asking as a row in the list, not a mode: type a question, press Return.
    private func askRow(_ question: String, isSelected: Bool) -> some View {
        launcherRow(icon: "nc-sparkle-3", tint: Theme.Palette.ink.opacity(0.85), isSelected: isSelected) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask Nod")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink)
                Text(question)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("Answers from every session")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.ink.opacity(0.45))
        }
    }

    private func resultRow(_ result: LauncherModel.Result, isSelected: Bool) -> some View {
        launcherRow(icon: result.icon, tint: Theme.Palette.muted, isSelected: isSelected) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                if let excerpt = result.excerpt {
                    Text(excerpt)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.ink.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(result.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.ink.opacity(0.45))
        }
    }

    /// One row shape for every kind of row. Written twice, the two had already
    /// drifted — different icon alignment, so a highlighted ask row and a
    /// highlighted session row didn't line their glyphs up.
    private func launcherRow(
        icon: String,
        tint: Color,
        isSelected: Bool,
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(icon)
                .icon(12)
                .foregroundStyle(tint)
                .frame(width: 16)
                .padding(.top, 1)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                .fill(Theme.Palette.surfaceStrong)
                .opacity(isSelected ? 1 : 0)
                .padding(.horizontal, 8)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Ask

    @ViewBuilder
    private var askPane: some View {
        Divider().overlay(Theme.Palette.border)
        if !canAskAcross {
            upsell
        } else if chat.isSending, launcherAnswerHasContent == false {
            // The chat's own indicator, not a bare spinner: it names the stage
            // it's on (searching → reading N sessions → writing), which is the
            // difference between "it's working" and "it's stuck".
            HStack {
                ThinkingIndicator(script: chat.thinkingScript)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        } else if let answer = launcherAnswer {
            answerPane(answer)
        } else if let errorText = chat.errorText {
            // Without this the fallback below is also the failure state, and a
            // failed ask sits on "Asking…" forever.
            hint(errorText)
        } else {
            hint("Asking across your sessions…")
        }
        // A stale answer must never read as the reply to what was just typed —
        // that's what the `isSending` gate above is for: the indicator holds the
        // floor until the answer is complete, then the whole answer replaces it.
    }

    /// The answer to what was asked *here* — anything older belongs to the
    /// Library's thread and would read as a reply to the empty field.
    private var launcherAnswer: KnowledgeChatStore.Message? {
        model.answer
    }

    /// Whether the answer has a finished paragraph to show yet. Until it does,
    /// the indicator holds the panel; after that the paragraphs do, and the
    /// indicator moves below them.
    private var launcherAnswerHasContent: Bool {
        guard let answer = launcherAnswer else { return false }
        return chat.isStreaming ? AnswerBlocks.hasComplete(in: answer.content) : !answer.content.isEmpty
    }

    private func answerPane(_ answer: KnowledgeChatStore.Message) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // The chat's own bubble, minus its chrome: same markdown
                // rendering (cached, not re-parsed per body pass) and the same
                // copy affordance the Library answer has.
                AssistantTextBubble(
                    content: answer.content,
                    showsBubble: false,
                    isStreaming: chat.isStreaming
                )
                if chat.isStreaming {
                    ThinkingIndicator(script: chat.thinkingScript)
                }
                if !answer.evidence.isEmpty, !chat.isStreaming {
                    evidence(answer.evidence, in: answer.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(maxHeight: 340)
    }

    /// Evidence is a pointer, not a transcript: a few sessions, one passage
    /// each, so the answer stays the thing you read first.
    private static let evidenceLimit = 3

    /// The passages the answer stands on. Shown in full rows rather than as
    /// chips because the point isn't which sessions were touched — it's what
    /// they actually said, with one click through to the session itself.
    private func evidence(
        _ all: [KnowledgeChatStore.Excerpt],
        in answerID: KnowledgeChatStore.Message.ID
    ) -> some View {
        let items = Array(all.prefix(Self.evidenceLimit))
        let hidden = all.count - items.count
        return
            VStack(alignment: .leading, spacing: 6) {
                Text("FROM YOUR SESSIONS")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.Palette.ink.opacity(0.45))
                VStack(spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { rank, item in
                        Button {
                            chat.noteOpenedSource(meetingID: item.meetingID, rank: rank, in: answerID)
                            onOpenMeeting(item.meetingID)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(item.title)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                                        .lineLimit(1)
                                    Text(item.date)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Theme.Palette.ink.opacity(0.45))
                                    Spacer(minLength: 4)
                                    Image("nc-arrow-up-right")
                                        .icon(9)
                                        .foregroundStyle(Theme.Palette.ink.opacity(0.4))
                                }
                                Text(item.text)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.Palette.ink.opacity(0.7))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                                    .fill(Theme.Palette.surface)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                                            .stroke(Theme.Palette.border, lineWidth: 0.5)
                                    )
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open this session")
                    }
                    if hidden > 0 {
                        Text("+\(hidden) more session\(hidden == 1 ? "" : "s")")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.Palette.ink.opacity(0.4))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 2)
                    }
                }
            }
    }

    /// Fail OPEN on an unresolved entitlement, matching the Library dock: the
    /// proxy is the real gate, so a Pro user with a failed fetch isn't blocked.
    private var canAskAcross: Bool {
        entitlements.entitlement == nil || entitlements.can(.askAcrossMeetings)
    }

    private var upsell: some View {
        HStack(spacing: 10) {
            Image("nc-sparkle-3")
                .icon(13)
                .foregroundStyle(Theme.Palette.violet)
            Text("Asking across sessions is a Pro feature.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.graphite)
            Spacer(minLength: 8)
            Button {
                NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
                onDismiss()
            } label: {
                Text("Upgrade")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.GlassButton.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            if model.isAnswering {
                if launcherAnswer != nil {
                    Button(action: onContinueInLibrary) {
                        keyLabel("⌘↩", "Continue in Library")
                    }
                    .buttonStyle(.plain)
                }
            } else {
                keyLabel("↩", primaryActionLabel)
                keyLabel("⌘↩", "Ask Nod")
                keyLabel("↑↓", "Navigate")
            }
            Spacer(minLength: 0)
            keyLabel("esc", "Close")
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    /// Return does whatever the highlighted row does, so the hint has to
    /// follow the selection rather than name one fixed action.
    private var primaryActionLabel: String {
        if case .ask = model.selectedRow { return "Ask Nod" }
        return "Open"
    }

    private func keyLabel(_ symbol: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                .frame(minWidth: 16)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.Palette.surfaceStrong)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Theme.Palette.border, lineWidth: 0.5)
                        )
                )
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.Palette.ink.opacity(0.55))
        }
    }
}

/// An indeterminate sweep along the field's bottom edge. Deliberately not a
/// pulsing or dimming label — animating the text's own opacity is what makes it
/// hard to read while it's working, which is the thing being fixed.
private struct SearchProgressLine: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                if isActive {
                    if reduceMotion {
                        // Reduced motion still needs the status, just not the
                        // travelling object: a steady bar, no sweep.
                        Rectangle()
                            .fill(Theme.Palette.ink.opacity(0.28))
                            .frame(width: width, height: 1.5)
                    } else {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Theme.Palette.ink.opacity(0),
                                        Theme.Palette.ink.opacity(0.55),
                                        Theme.Palette.ink.opacity(0)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: width * 0.4, height: 1.5)
                            .offset(x: sweep ? width * 0.6 : -width * 0.4)
                            .animation(
                                .easeInOut(duration: 1.1).repeatForever(autoreverses: false),
                                value: sweep
                            )
                            .onAppear { sweep = true }
                            .onDisappear { sweep = false }
                    }
                }
            }
            .frame(height: 1.5)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 1.5)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.18), value: isActive)
    }
}
