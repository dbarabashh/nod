import SwiftUI

/// The first line of a form that opens in place: what it does, the product it
/// does it in, and the one quiet word that closes it again.
struct InlineFormHeader: View {
    let title: String
    let provider: IntegrationProvider?
    let dismissTitle: String
    let onDismiss: () -> Void

    init(
        _ title: String,
        provider: IntegrationProvider? = nil,
        dismissTitle: String = "Close",
        onDismiss: @escaping () -> Void
    ) {
        self.title = title
        self.provider = provider
        self.dismissTitle = dismissTitle
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(spacing: 6) {
            if let provider {
                ProviderMark(provider: provider, size: 12)
            }
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 0)
            Button(dismissTitle, action: onDismiss)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.muted)
                .buttonStyle(.plain)
                .linkCursor()
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        InlineFormHeader("Create a task") {}
        InlineFormHeader("Send a message in Slack", provider: .slack, dismissTitle: "Cancel") {}
        InlineFormHeader("Schedule a follow-up", provider: .googleCalendar) {}
            .disabled(true)
    }
    .frame(width: 320)
    .padding(24)
    .background(Theme.Palette.bg)
}
