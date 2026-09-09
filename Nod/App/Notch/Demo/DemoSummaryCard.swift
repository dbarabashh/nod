import SwiftUI

/// The recap, available the moment the meeting ends — no spinner, no "your
/// summary will be ready shortly".
///
/// The one stage tall enough to need scrolling. It scrolls itself a little way
/// down during the final seconds: on a landing video nobody is there to drag,
/// and the point being made is that there is *more* below — the work Nod already
/// finished and the meeting it already booked.
struct DemoSummaryCard: View {
    let summary: DemoSummary

    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the card stops growing and starts scrolling. Sized to leave the
    /// notch a card rather than a full-height panel, and to keep the whole
    /// surface inside `NotchPanel.canvasSize`.
    private static let maxHeight: CGFloat = 300
    private static let autoScrollTarget = "completed"

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            greeting
            head
            scroller
        }
        .onAppear { revealed = true }
    }

    /// The one personal line in the whole card — everything below it is about
    /// the meeting, this is addressed to the person reading it.
    private var greeting: some View {
        Text(summary.greeting)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(Theme.Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var head: some View {
        HStack(spacing: 8) {
            Image("nc-file")
                .icon(12)
                .foregroundStyle(Theme.Palette.brand)
            Text(summary.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 0)
            DemoScrollHint()
        }
    }

    private var scroller: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 13) {
                    section("Summary") {
                        paragraph(summary.overview)
                    }
                    section("Key insight") {
                        paragraph(summary.keyInsight)
                    }
                    section("Decisions") {
                        bullets(summary.decisions)
                    }
                    section("Action items") {
                        bullets(summary.actionItems)
                    }
                    section("Completed automatically") {
                        ticks(summary.completed)
                    }
                    .id(Self.autoScrollTarget)
                    event
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: Self.maxHeight)
            .task {
                guard !reduceMotion else { return }
                // Late enough that the top has been read first.
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                withAnimation(.easeInOut(duration: 2.2)) {
                    proxy.scrollTo(Self.autoScrollTarget, anchor: .top)
                }
            }
        }
    }

    // MARK: - Pieces

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(title, size: .compact)
            content()
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .regular))
            .foregroundStyle(Theme.Palette.graphite)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 7) {
                    Circle()
                        .fill(Theme.Palette.muted.opacity(0.7))
                        .frame(width: 3, height: 3)
                        .padding(.top, 5.5)
                    Text(item)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(Theme.Palette.graphite)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func ticks(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 7) {
                    Image("nc-check")
                        .icon(8)
                        .foregroundStyle(Theme.Palette.success)
                        .padding(.top, 2)
                    Text(item)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(Theme.Palette.graphite)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var event: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                DemoToolIcon(tool: .calendar, size: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.event.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                    Text(summary.event.when)
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(Theme.Palette.muted)
                }
                Spacer(minLength: 0)
                Text(summary.event.status)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.success)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous).fill(Theme.Palette.success.opacity(0.16))
                    )
            }

            chips("Attendees", summary.event.attendees)
            chips("Attached", summary.event.attachments)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                .fill(Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                )
        )
    }

    private func chips(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .kerning(0.5)
                .foregroundStyle(Theme.Palette.muted.opacity(0.8))
            DemoChipFlow(items: items)
        }
    }
}

/// A hint that there is more under the fold, since a landing video has no
/// cursor to reveal a scrollbar.
private struct DemoScrollHint: View {
    @State private var nudging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image("nc-chevron-down")
            .icon(9)
            .foregroundStyle(Theme.Palette.muted)
            .offset(y: nudging ? 1.5 : -1.5)
            .onAppear { nudging = !reduceMotion }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: nudging
            )
    }
}

/// Wrapping chips, laid out by hand: `Grid` is macOS 13 but wraps by column
/// count, and these are variable-width labels that have to flow.
private struct DemoChipFlow: View {
    let items: [String]
    var perRow: Int = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { item in
                        Text(item)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.Palette.graphite)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous).fill(Theme.Palette.surfaceStrong)
                            )
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var rows: [[String]] {
        stride(from: 0, to: items.count, by: perRow).map { start in
            Array(items[start ..< min(start + perRow, items.count)])
        }
    }
}
