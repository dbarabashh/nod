import SwiftUI

struct SettingsView: View {
    @ObservedObject private var hotkey = HotkeyManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

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

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 460, height: 470, alignment: .topLeading)
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

#Preview {
    SettingsView()
}
