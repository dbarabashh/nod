import AppKit
import SwiftUI

/// Where a person goes when Nod is wrong or missing something: two tiles that
/// open a pre-addressed email in whatever handles mail on this Mac, with the
/// build and machine facts already written under the signature.
struct SupportSection: View {
    @EnvironmentObject private var analytics: ProductAnalytics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Support")
            HStack(spacing: 12) {
                SupportTile(icon: "nc-lightbulb-3", title: "Request a feature") {
                    open(.feature)
                }
                SupportTile(icon: "nc-bug", title: "Report a bug") {
                    open(.bug)
                }
            }
        }
    }

    private func open(_ kind: SupportReport.Kind) {
        let report = SupportReport(kind: kind, environment: .current(), triggeredFrom: "Settings")
        guard let url = report.url else { return }
        Log.ui.info("SupportSection opening \(kind.subject) id=\(report.reportID)")
        analytics.record(.supportOpened, properties: .init(surface: .settings, detail: kind == .bug ? .bug : .feature))
        NSWorkspace.shared.open(url)
    }
}

private struct SupportTile: View {
    let icon: String
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(icon)
                    .icon(16)
                    .foregroundStyle(Theme.Palette.brand)
                Text(title)
                    .textStyle(Theme.Typography.uiEmphasis)
                    .foregroundStyle(Theme.Palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous))
            .surfaceCard(emphasis: .strong)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                    .stroke(Theme.Palette.brand.opacity(isHovering ? 0.6 : 0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .linkCursor()
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

#Preview {
    SupportSection()
        .environmentObject(ProductAnalytics.preview)
        .padding(24)
        .frame(width: 620)
        .background(Theme.Palette.bg)
}
