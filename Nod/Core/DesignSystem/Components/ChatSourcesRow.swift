import SwiftUI

/// Where an answer came from, folded into one pill until asked.
///
/// It used to be a labelled strip of chips under every answer — a header, a
/// row, and a horizontal scroll that cut the last source in half. Sources are
/// there to be checked, not read: most answers are taken on trust, and the
/// ones that aren't are worth a click. So the default is a pill wearing the
/// marks of what it drew on, and the list is one press away.
struct ChatSourcesRow: View {
    let sources: [KnowledgeChatStore.SessionRef]
    /// The rank is what the retrieval feedback log records, so it comes from
    /// the order shown rather than from the caller's own idea of it.
    let onOpen: (KnowledgeChatStore.SessionRef, Int) -> Void

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ordered: [KnowledgeChatStore.SessionRef] {
        Self.ordered(sources)
    }

    private var listed: ArraySlice<KnowledgeChatStore.SessionRef> {
        ordered.prefix(Self.listLimit)
    }

    private var overflow: ArraySlice<KnowledgeChatStore.SessionRef> {
        ordered.dropFirst(Self.listLimit)
    }

    /// Sessions first — they are the spine of the answer and they open — then
    /// the apps it read off the screen. A static because the collapse hides
    /// things: a source that falls past `listLimit` is named only in a muted
    /// line, and a source that falls past `markLimit` is not drawn at all, so
    /// the order that decides which is worth pinning.
    static func ordered(_ sources: [KnowledgeChatStore.SessionRef]) -> [KnowledgeChatStore.SessionRef] {
        sources.filter { !$0.isApp } + sources.filter(\.isApp)
    }

    var body: some View {
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                pill
                if isExpanded {
                    list
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.standard(reduceMotion: reduceMotion), value: isExpanded)
        }
    }

    private var pill: some View {
        Button { isExpanded.toggle() } label: {
            HStack(spacing: 6) {
                marks
                Text("Sources")
                    .font(.system(size: 11, weight: .medium))
                if ordered.count > Self.markLimit {
                    Text("\(ordered.count)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.muted)
                }
            }
            .foregroundStyle(Theme.Palette.ink.opacity(0.75))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.Palette.surface)
                    .overlay(Capsule().stroke(Theme.Palette.border, lineWidth: 0.5))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide sources" : "Show what this answer drew on")
        .linkCursor()
    }

    /// The marks overlap, the way a row of avatars does: at this size the
    /// point is "three things, and one of them was Chrome", not three
    /// separately legible icons.
    private var marks: some View {
        HStack(spacing: -4) {
            ForEach(Array(ordered.prefix(Self.markLimit).enumerated()), id: \.element.id) { _, source in
                SourceMark(source: source, size: 13)
                    .background(
                        Circle()
                            .fill(Theme.Palette.bgSoft)
                            .frame(width: 17, height: 17)
                    )
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(listed.enumerated()), id: \.element.id) { rank, source in
                row(source, rank: rank)
            }
            if !overflow.isEmpty {
                Text("Also \(overflow.map(\.title).joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 2)
    }

    /// A session opens; an app is a label. The pointer says which without a
    /// second word saying so.
    @ViewBuilder
    private func row(_ source: KnowledgeChatStore.SessionRef, rank: Int) -> some View {
        if source.isApp {
            label(source)
        } else {
            Button { onOpen(source, rank) } label: { label(source) }
                .buttonStyle(.plain)
                .help("Open this session")
                .linkCursor()
        }
    }

    private func label(_ source: KnowledgeChatStore.SessionRef) -> some View {
        HStack(spacing: 7) {
            SourceMark(source: source, size: 14)
            Text(source.title)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.Palette.ink.opacity(0.8))
        .contentShape(Rectangle())
    }

    /// Enough to say what kind of answer this was without becoming a list.
    static let markLimit = 3
    /// Past this the names stop being checkable and start being a paragraph.
    static let listLimit = 5
}

/// One source's mark: the app's own icon for something read off the screen, a
/// document glyph for a recorded session.
struct SourceMark: View {
    let source: KnowledgeChatStore.SessionRef
    var size: CGFloat = 13

    var body: some View {
        if let bundleID = source.bundleID,
           let icon = AppDirectory.icon(for: AppDirectory.identity(forBundleID: bundleID)) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(source.isApp ? "nc-window-pointer" : "nc-file")
                .icon(size * 0.72)
                .foregroundStyle(Theme.Palette.muted)
                .frame(width: size, height: size)
        }
    }
}
