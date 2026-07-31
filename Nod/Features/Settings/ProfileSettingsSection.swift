import SwiftUI

/// "What Nod remembers about you" — the visible, editable face of the
/// always-on profile. Loads the current row on appear, seeds the fields
/// once, and upserts on Save with a transient confirmation.
struct ProfileSettingsSection: View {
    @ObservedObject var store: ProfileStore

    @State private var name = ""
    @State private var preferences = ""
    @State private var seeded = false
    @State private var saveState: SaveState = .idle

    private enum SaveState: Equatable {
        case idle, saving, saved, failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHAT NOD REMEMBERS ABOUT YOU")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Palette.muted)

            Text("Stored privately to your account; nothing here is shared.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            field(label: "Your name", placeholder: "Alex", text: $name)
            field(
                label: "What should Nod help you win at?",
                placeholder: "Track what people commit to me, surface risks early, and tell me how to make my point more persuasively",
                text: $preferences,
                helper: "Your edge in every conversation. Nod tailors each summary to it — so you follow through, stay on top, and get credit for your work.",
                multiline: true
            )

            saveRow
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
        .task {
            await store.load()
            seedIfNeeded()
        }
        .onReceive(store.$profile) { _ in seedIfNeeded() }
    }

    private var saveRow: some View {
        HStack(spacing: 10) {
            Button(action: save) {
                Text(saveState == .saving ? "Saving…" : "Save")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Theme.GlassButton.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .glassButtonSurface(Capsule(style: .continuous))
                    .opacity(saveState == .saving ? 0.7 : 1)
            }
            .buttonStyle(.plain)
            .disabled(saveState == .saving)

            statusLabel
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch saveState {
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(Theme.Palette.success)
                .transition(.opacity)
        case let .failed(message):
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.danger)
                .lineLimit(1)
        default:
            EmptyView()
        }
    }

    private func field(label: String, placeholder: String, text: Binding<String>, helper: String? = nil, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.Palette.muted)
            if let helper {
                Text(helper)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(placeholder, text: text, axis: multiline ? .vertical : .horizontal)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(multiline ? 2 ... 4 : 1 ... 1)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .fill(Theme.Palette.surfaceStrong)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                                .stroke(Theme.Palette.border, lineWidth: 0.5)
                        )
                )
        }
    }

    private func seedIfNeeded() {
        guard !seeded, let profile = store.profile else { return }
        name = profile.displayName
        preferences = profile.preferences
        seeded = true
    }

    private func save() {
        saveState = .saving
        Task {
            do {
                try await store.update {
                    $0.displayName = name
                    $0.preferences = preferences
                }
                withAnimation { saveState = .saved }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if saveState == .saved { withAnimation { saveState = .idle } }
            } catch {
                withAnimation { saveState = .failed(error.localizedDescription) }
            }
        }
    }
}
