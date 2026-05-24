import SwiftUI

/// List of past meetings, newest first. State-machine UI: spinner while the
/// initial load runs, empty placeholder, list, or error-with-retry. Tapping a
/// row pushes the detail view. Supports client-side search via the toolbar
/// search field (filters the already-loaded list — server-side full-text
/// search is a follow-up once volumes warrant it).
///
/// Issue #14.
struct HistoryView: View {
    @EnvironmentObject private var meetingStore: MeetingStore

    @State private var searchQuery: String = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Meetings")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: { Task { await meetingStore.refresh() } }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(meetingStore.loadState == .loading)
                    }
                }
                .searchable(text: $searchQuery, prompt: "Search meetings")
        }
        .background(Theme.Palette.bg.ignoresSafeArea())
        .task {
            // Lazy-load: fetch once when the window opens. Manual refresh
            // available via the toolbar button.
            if case .idle = meetingStore.loadState {
                await meetingStore.refresh()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch meetingStore.loadState {
        case .idle, .loading:
            loadingState
        case .failed(let message):
            errorState(message: message)
        case .loaded:
            if meetingStore.meetings.isEmpty {
                emptyState
            } else if filteredMeetings.isEmpty {
                noMatchesState
            } else {
                meetingsList
            }
        }
    }

    // MARK: - Filter

    /// Trimmed, lower-cased query for matching.
    private var normalizedQuery: String {
        searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Substring match on title + summary. Client-side because the full set
    /// is already in memory (capped at 500 by MeetingStore.refresh); when
    /// volumes outgrow that we move this to a server-side `.ilike` on title
    /// + summary.
    private var filteredMeetings: [Meeting] {
        let q = normalizedQuery
        if q.isEmpty { return meetingStore.meetings }
        return meetingStore.meetings.filter { meeting in
            if let title = meeting.title?.lowercased(), title.contains(q) { return true }
            return meeting.summary.lowercased().contains(q)
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Theme.Palette.ink)
            Text("Loading meetings…")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(Theme.Palette.muted)
            Text("No meetings yet.")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text("Hit record on the floating panel to start your first.")
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Theme.Palette.graphite)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    private var noMatchesState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.Palette.muted)
            Text("No matches for \u{201C}\(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .multilineTextAlignment(.center)
            Text("Try a different word — search looks at titles and summaries.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.graphite)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.Palette.warning)
            Text("Couldn't load meetings.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text(message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.graphite)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { Task { await meetingStore.refresh() } }) {
                Text("Retry")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(Capsule(style: .continuous).fill(Theme.Gradients.buttonBrand))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    private var meetingsList: some View {
        // `List` on macOS is lazy by default — only visible rows instantiate
        // their views even for 500+ items, so this scales without an
        // explicit LazyVStack wrapper.
        List(filteredMeetings) { meeting in
            NavigationLink(value: meeting) {
                MeetingRow(meeting: meeting)
            }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Theme.Palette.border)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationDestination(for: Meeting.self) { meeting in
            MeetingDetailView(meeting: meeting)
        }
    }
}

// MARK: - Row

private struct MeetingRow: View {
    let meeting: Meeting

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(meeting.displayTitle(dateFormatter: Self.dateFormatter))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(meeting.language.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(Theme.Palette.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Theme.Palette.surface)
                    )
            }

            Text(meeting.summaryPreview)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.graphite)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.vertical, 6)
    }
}
