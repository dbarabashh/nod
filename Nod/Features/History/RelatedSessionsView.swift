import SwiftUI

/// The humble face of the entity graph: the people/projects/topics this
/// session mentions, and other sessions that share them. No node diagram —
/// just chips and a list. Renders nothing until (and unless) there's
/// something to show.
struct RelatedSessionsView: View {
    let meeting: Meeting

    @EnvironmentObject private var entityStore: EntityStore

    @State private var entities: [Entity] = []
    @State private var related: [Meeting] = []

    private static let agoFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        Group {
            if !entities.isEmpty || !related.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    Divider().overlay(Theme.Palette.border)
                    if !entities.isEmpty { mentioned }
                    if !related.isEmpty { relatedList }
                }
                .padding(.top, 4)
            }
        }
        // Reload when navigating between sessions in the same view.
        .task(id: meeting.id) { await load() }
    }

    private var mentioned: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Mentioned")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(entities) { entity in
                        chip(entity)
                    }
                }
                .padding(.bottom, 2)
            }
        }
    }

    private func chip(_ entity: Entity) -> some View {
        HStack(spacing: 5) {
            Image(entity.kind.icon)
                .icon(9)
                .foregroundStyle(tint(entity.kind))
            Text(entity.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Palette.ink.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(tint(entity.kind).opacity(0.12))
                .overlay(Capsule().stroke(tint(entity.kind).opacity(0.25), lineWidth: 0.5))
        )
    }

    private var relatedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Related sessions")
            VStack(spacing: 6) {
                ForEach(related) { session in
                    NavigationLink(value: session) {
                        relatedRow(session)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func relatedRow(_ session: Meeting) -> some View {
        HStack(spacing: 10) {
            Image(session.kind.icon)
                .icon(12)
                .foregroundStyle(Theme.Palette.muted)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle(dateFormatter: Self.fallbackDateFormatter))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.92))
                    .lineLimit(1)
                Text(Self.agoFormatter.localizedString(for: session.startedAt, relativeTo: Date()))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.muted)
            }
            Spacer(minLength: 0)
            Image("nc-chevron-right")
                .icon(10)
                .foregroundStyle(Theme.Palette.muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Theme.Palette.muted)
    }

    private func tint(_ kind: EntityKind) -> Color {
        switch kind {
        case .person: Theme.Palette.violet
        case .project: Theme.Palette.cyan
        case .topic: Theme.Palette.success
        }
    }

    private func load() async {
        // Two independent round-trips — overlap them so the view doesn't pay
        // both latencies in series.
        async let loadedEntities = entityStore.entities(forMeeting: meeting.id)
        async let loadedRelated = entityStore.relatedMeetings(to: meeting.id)
        entities = await loadedEntities
        related = await loadedRelated
    }

    private static let fallbackDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
