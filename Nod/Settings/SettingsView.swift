import SwiftUI

struct SettingsView: View {
    @ObservedObject private var hotkey = HotkeyManager.shared

    /// Optional so previews (and any future env-free mount) work without a
    /// live Supabase-backed store. nil → the profile section is omitted.
    private let profileStore: ProfileStore?

    init(profileStore: ProfileStore? = nil) {
        self.profileStore = profileStore
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let profileStore {
                    ProfileSettingsSection(store: profileStore)
                }

                section(title: "Suggest reply hotkey") {
                    Text("Press this shortcut during a meeting to get a real-time reply suggestion. Works in any app — Zoom, Meet, Teams.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)

                    HotkeyRecorderView(hotkey: hotkey, action: .suggestReply)
                        .padding(.top, 2)

                    Text("Default ⌘⇧S. Avoid ⌘S — every Mac app uses it for Save and the hotkey would be stolen system-wide.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }

                section(title: "Show / hide panel hotkey") {
                    Text("Toggle the floating panel from anywhere — hide it while you work, bring it back when you need it. Works even when another app is focused.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)

                    HotkeyRecorderView(hotkey: hotkey, action: .togglePanel)
                        .padding(.top, 2)

                    Text("Default ⌘⇧H. Avoid ⌘H — macOS reserves it for Hide and the hotkey would be stolen system-wide.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            .padding(20)
        }
        .frame(width: 460, height: 560, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.12, blue: 0.22),
                    Color(red: 0.06, green: 0.07, blue: 0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))
            Text("Settings")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundColor(.white.opacity(0.5))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        )
    }
}

/// "What Nod remembers about you" — the visible, editable face of the
/// always-on profile. Loads the current row on appear, seeds the fields
/// once, and upserts on Save with a transient confirmation.
private struct ProfileSettingsSection: View {
    @ObservedObject var store: ProfileStore

    @State private var name = ""
    @State private var role = ""
    @State private var focus = ""
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
                .foregroundColor(.white.opacity(0.5))

            Text("Added to every summary and answer so Nod responds with your context in mind. Stored privately to your account; nothing here is shared.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)

            field(label: "Your name", placeholder: "Alex", text: $name)
            field(label: "What you do", placeholder: "Product designer at an early-stage startup", text: $role)
            field(label: "What you're working on", placeholder: "Shipping our iOS app, hiring two engineers", text: $focus, multiline: true)

            saveRow
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        )
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
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Capsule(style: .continuous).fill(Theme.Gradients.buttonBrand))
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

    private func field(label: String, placeholder: String, text: Binding<String>, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundColor(.white.opacity(0.4))
            TextField(placeholder, text: text, axis: multiline ? .vertical : .horizontal)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .lineLimit(multiline ? 2...4 : 1...1)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                        )
                )
        }
    }

    private func seedIfNeeded() {
        guard !seeded, let profile = store.profile else { return }
        name = profile.displayName
        role = profile.role
        focus = profile.focus
        seeded = true
    }

    private func save() {
        saveState = .saving
        Task {
            do {
                try await store.save(displayName: name, role: role, focus: focus)
                withAnimation { saveState = .saved }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if saveState == .saved { withAnimation { saveState = .idle } }
            } catch {
                withAnimation { saveState = .failed(error.localizedDescription) }
            }
        }
    }
}

#Preview {
    SettingsView()
}
