import SwiftUI

/// The Beats surface: the questions that ask themselves, and what each one
/// last came back with.
///
/// Two columns of cards rather than a list of rows — a beat is chosen by
/// reading what it will do for you, and a sentence needs the width. Every
/// answer is an ordinary thread, so a card is a way into a conversation rather
/// than a dead-end report.
struct BeatsView: View {
    @EnvironmentObject private var beats: BeatStore
    @EnvironmentObject private var integrations: IntegrationService

    /// Opens the thread a run wrote, in the chat surface.
    let onOpenThread: (UUID) -> Void
    /// A report another surface asked to land on, straight past the grid.
    let open: BeatOpenRequest?

    @State private var editor: BeatEditor.Mode?
    @State private var opened: Beat?
    @State private var category: BeatTemplates.Category = .day

    init(open: BeatOpenRequest? = nil, onOpenThread: @escaping (UUID) -> Void) {
        self.open = open
        self.onOpenThread = onOpenThread
        _opened = State(initialValue: open?.beat)
    }

    /// Wide enough for two cards side by side at the window's usual size, and
    /// one when the sidebar and a focused session have taken the rest.
    private let columns = [GridItem(.adaptive(minimum: 268), spacing: 12)]

    var body: some View {
        Group {
            if let opened {
                BeatDetailView(
                    beat: beats.beats.first { $0.id == opened.id } ?? opened,
                    onBack: { self.opened = nil },
                    onOpenThread: onOpenThread,
                    onEdit: { editor = .edit(beats.beats.first { $0.id == opened.id } ?? opened) },
                    focusRunID: open?.beat.id == opened.id ? open?.runID : nil
                )
                .sheet(item: $editor) { mode in BeatEditor(mode: mode) }
            } else {
                grid
            }
        }
        .onChange(of: open) { request in
            if let request { opened = request.beat }
        }
    }

    private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                header
                if !beats.beats.isEmpty {
                    section("Yours") {
                        ForEach(beats.beats) { beat in
                            BeatCard(
                                title: beat.displayTitle,
                                summary: BeatsView.preview(of: beat, in: beats),
                                schedule: BeatSchedule.describe(beat),
                                note: BeatSchedule.lastRun(beats.latestRun(of: beat.id)),
                                isPaused: !beat.enabled,
                                // The card itself is the way in — a beat exists
                                // to be read, so reading it cannot be a small
                                // button in the corner of its own row.
                                onOpen: { opened = beat },
                                onEdit: { editor = .edit(beat) },
                                onDelete: { Task { await beats.delete(beat.id) } },
                                setUp: nil
                            )
                        }
                    }
                }
                library
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 940, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .task { await beats.refresh() }
        .sheet(item: $editor) { mode in
            BeatEditor(mode: mode)
        }
    }

    /// What a beat's card shows under its name: the opening line of the last
    /// report when there is one, and the question itself when there isn't. A
    /// card that keeps showing the prompt after the beat has answered twice is
    /// showing the least interesting thing it knows.
    static func preview(of beat: Beat, in store: BeatStore) -> String {
        guard let run = store.latestRun(of: beat.id), run.status == .done,
              let report = store.reports[run.id]
        else { return beat.prompt }
        return BeatDetailView.summary(of: run, report: report)
    }

    /// The library, behind its categories. A hundred cards in one scroll is a
    /// menu to read; a beat is meant to read like a sentence you could have
    /// typed yourself, so only one category is on screen at a time.
    private var library: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(beats.beats.isEmpty ? "Start with one of these" : "Library")
            categoryTabs
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(BeatTemplates.inCategory(category, linked: integrations.linked)) { template in
                    BeatCard(
                        title: template.title,
                        summary: template.summary,
                        schedule: BeatSchedule.describe(template),
                        note: template.requires?.displayName,
                        isPaused: false,
                        onOpen: nil,
                        onEdit: nil,
                        onDelete: nil,
                        setUp: { Task { await create(template) } }
                    )
                }
            }
            if BeatTemplates.inCategory(category, linked: integrations.linked).isEmpty {
                // Every beat in this category reads a product that isn't
                // connected. Saying so beats an empty grid — and beats offering
                // a beat that would come back with nothing.
                Text("These read from a product you haven't connected yet. Settings → Integrations.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.6))
                    .padding(.vertical, 8)
            }
        }
    }

    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(BeatTemplates.Category.allCases) { option in
                    SecondaryPillButton(option.rawValue, size: .tab, isSelected: option == category) {
                        category = option
                    }
                }
            }
            .padding(.bottom, 2)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Beats")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text("A question Nod keeps asking, answered where you'll see it.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.6))
            }
            Spacer(minLength: 12)
            GlassPillButton("New beat", leadingIcon: "nc-plus") { editor = .create }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                content()
            }
        }
    }

    private func create(_ template: BeatTemplates.Template) async {
        await beats.create(
            title: template.title,
            prompt: template.prompt,
            cadence: template.cadence,
            hour: template.hour,
            minute: template.minute,
            weekday: template.weekday,
            dayOfMonth: template.dayOfMonth
        )
    }
}

/// One card in the grid — a beat you have, or one on offer.
///
/// A beat you have is opened by clicking it, anywhere: the report is the point,
/// and a card whose only way in was a small text button read as decoration. Its
/// housekeeping — edit, delete — lives in the overflow menu, which is where
/// every list of this shape puts it.
private struct BeatCard: View {
    let title: String
    let summary: String
    let schedule: String
    /// What became of the last run, when there was one.
    let note: String?
    let isPaused: Bool
    /// Nil for a template — there is nothing to read yet.
    let onOpen: (() -> Void)?
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    /// Nil for a beat that already exists.
    let setUp: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(1)
                    if isPaused {
                        Text("Paused")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(Theme.Palette.ink.opacity(0.65))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule(style: .continuous).fill(Theme.Palette.surfaceStrong))
                    }
                    Spacer(minLength: 0)
                    if onEdit != nil || onDelete != nil {
                        Menu {
                            if let onEdit { Button("Edit…", action: onEdit) }
                            if let onDelete { Button("Delete", role: .destructive, action: onDelete) }
                        } label: {
                            Image("nc-chevron-down")
                                .icon(9)
                                .foregroundStyle(Theme.Palette.ink.opacity(isHovering ? 0.7 : 0.35))
                        }
                        .plainMenuChrome()
                        .fixedSize()
                    }
                }
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.72))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: 32, alignment: .top)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider().overlay(Theme.Palette.border)

            HStack(spacing: 6) {
                Image("nc-stopwatch")
                    .icon(10)
                    .foregroundStyle(Theme.Palette.ink.opacity(0.5))
                // Both, not one or the other: a card that swapped its schedule
                // for "last ran an hour ago" stopped answering the question the
                // row exists to answer — when does this happen next.
                Text([schedule, note].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let setUp {
                    Button(action: setUp) {
                        HStack(spacing: 4) {
                            Image("nc-plus").icon(9)
                            Text("Set up")
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                                .fill(Theme.Palette.surfaceStrong)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .linkCursor()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous)
                .fill(isHovering && onOpen != nil ? Theme.Palette.surfaceStrong : Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                )
        )
        .opacity(isPaused ? 0.7 : 1)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous))
        .onTapGesture { onOpen?() }
        .onHover { isHovering = $0 }
        .linkCursor()
    }
}

#if DEBUG
    #Preview("Beats") {
        BeatsView(onOpenThread: { _ in })
            .environmentObject(BeatStore(supabase: nil, auth: nil))
            .frame(width: 900, height: 620)
            .background(Theme.Palette.bg)
    }
#endif

/// What Today hands over when a row is a report, not the Beats page: the beat
/// to open and the run whose report the person clicked.
struct BeatOpenRequest: Equatable {
    let beat: Beat
    let runID: UUID?
}
