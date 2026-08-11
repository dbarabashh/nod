import SwiftUI

/// The main window's demo section: a small sidebar of scripted "modes" —
/// Morning Briefing, Catch Up, Action Plan, Deep Work, Inbox, Meeting Prep,
/// Daily Recap — showing the breadth of what Nod does beyond one meeting's
/// transcript. Content is fully scripted per `DemoScenario`, the same
/// fictional story the notch's own demo already tells.
struct DemoDailyModesView: View {
    let scenario: DemoScenario

    /// Daily Recap opens by default — the mode that reads as "here's
    /// everything", the natural front door into the other six.
    @State private var mode: DemoDailyMode = .dailyRecap

    private var content: [DemoDailyMode: DemoDailyModeContent] {
        DemoDailyMode.content(for: scenario)
    }

    var body: some View {
        HStack(spacing: 0) {
            modeList
            Rectangle()
                .fill(Theme.Palette.border)
                .frame(width: 0.5)
                .frame(maxHeight: .infinity)
            detail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var modeList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(DemoDailyMode.allCases) { candidate in
                modeRow(candidate)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func modeRow(_ candidate: DemoDailyMode) -> some View {
        let isSelected = candidate == mode
        return Button {
            mode = candidate
        } label: {
            HStack(spacing: 9) {
                Image(candidate.icon)
                    .icon(12.5)
                    .frame(width: 16)
                Text(candidate.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Theme.Palette.ink : Theme.Palette.ink.opacity(0.72))
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                    .fill(Theme.Palette.surfaceStrong)
                    .opacity(isSelected ? 1 : 0)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Theme.Palette.brand)
                        .frame(width: 2)
                        .padding(.vertical, 7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        // Every case is authored for every scenario — see the four
        // `DemoDailyModeContent+*.swift` files — so this is never nil in
        // practice; the guard just keeps the view from force-unwrapping.
        if let entry = content[mode] {
            DemoDailyModeDetail(mode: mode, content: entry)
                .id(mode)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// One mode's content: the personal opener when it has one, the summary
/// line, the scripted rows, and a single call to action.
private struct DemoDailyModeDetail: View {
    let mode: DemoDailyMode
    let content: DemoDailyModeContent

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                header
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(content.rows) { row in
                        DemoDailyRowView(row: row)
                    }
                }
                if let footerAction = content.footerAction {
                    footer(footerAction)
                }
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let greeting = content.greeting {
                Text(greeting)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
            } else {
                HStack(spacing: 8) {
                    Image(mode.icon)
                        .icon(13)
                        .foregroundStyle(Theme.Palette.brand)
                    Text(mode.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                }
            }
            Text(content.summary)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Theme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// No-op on purpose: every action here points at a Slack thread, an
    /// inbox, a brief — surfaces the scripted demo doesn't otherwise open.
    /// The button exists to show the shape of the flow, not to complete it.
    private func footer(_ label: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12.5, weight: .semibold))
            Image("nc-arrow-up-right")
                .icon(9)
        }
        .foregroundStyle(Theme.GlassButton.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassButtonSurface(Capsule(style: .continuous))
    }
}

private struct DemoDailyRowView: View {
    let row: DemoDailyRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            glyph
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(Theme.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let meta = row.meta {
                Text(meta)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                .fill(Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private var glyph: some View {
        switch row.glyph {
        case let .person(name, tint):
            DemoAvatarView(name: name, tint: tint)
        case let .tool(tool):
            DemoToolIcon(tool: tool, size: 22)
        case let .system(icon, tint):
            Image(icon)
                .icon(12)
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(tint.opacity(0.14)))
        }
    }
}

/// A teammate's placeholder photo, keyed to their name so the same person
/// always shows the same face. Falls back to colored initials while the
/// photo loads and if it never does — a scripted demo reaching an external
/// host must still look right with no network.
private struct DemoAvatarView: View {
    let name: String
    let tint: Color

    var body: some View {
        AsyncImage(url: DemoDailyGlyph.avatarURL(for: name)) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                initials
            }
        }
        .frame(width: 26, height: 26)
        .clipShape(Circle())
    }

    private var initials: some View {
        Text(DemoDailyGlyph.initials(for: name))
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Circle().fill(tint.opacity(0.85)))
    }
}

#Preview {
    DemoDailyModesView(scenario: .productEngineering)
        .frame(width: 900, height: 640)
        .background(Theme.Palette.bg)
}
