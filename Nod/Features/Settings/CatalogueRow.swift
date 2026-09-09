import SwiftUI

/// A product authorized outside Nod's own list — connected straight at the
/// broker, before an adapter for it existed.
///
/// Quieter than a `providerRow` — no chevron, no team picker, no settings —
/// because there is nothing to configure: the grant is real and Nod cannot spend
/// it. Saying so on the row is the difference between an honest "authorized" and
/// a checkmark that implies working features.
struct CatalogueRow: View {
    let app: CatalogueApp

    var body: some View {
        HStack(spacing: 12) {
            CatalogueMark(slug: app.slug, tiled: true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                    ForEach(app.categories, id: \.self) { category in
                        TagPill(category)
                    }
                }
                Text("Authorized. Nod can't act in it yet.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var control: some View {
        StatusLabel(icon: "nc-check", title: "Connected", tint: Theme.Palette.success)
            .accessibilityLabel("\(app.name) connected")
    }
}

#Preview {
    VStack(spacing: 0) {
        CatalogueRow(
            app: CatalogueApp(
                slug: "clickup",
                name: "ClickUp",
                description: "Tasks, docs and goals in one place.",
                categories: ["Productivity"]
            )
        )
        SettingsRowDivider()
        CatalogueRow(
            app: CatalogueApp(
                slug: "notion",
                name: "Notion",
                description: "",
                categories: ["Productivity", "Docs"]
            )
        )
    }
    .frame(width: 560)
    .background(Theme.Palette.surface)
}
