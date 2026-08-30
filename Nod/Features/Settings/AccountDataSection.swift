import SwiftUI

/// GDPR data-rights surface: export everything as JSON (Art. 15 / 20) and
/// permanently delete the account (Art. 17). Both call Edge Functions that do
/// the real work server-side; this view is just the affordance + confirmation.
struct AccountDataSection: View {
    @ObservedObject var auth: AuthService
    @ObservedObject var export: AccountExportService

    @State private var confirmingDelete = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                SettingsRow(
                    icon: "nc-paper-plane-2",
                    title: "Export my data",
                    subtitle: exportSubtitle
                ) {
                    Button(action: { Task { await export.export() } }) {
                        Text(isExporting ? "Exporting…" : "Export")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(Theme.GlassButton.text)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .glassButtonSurface(Capsule(style: .continuous))
                            .opacity(isExporting ? 0.7 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(isExporting)
                }
            }

            SettingsCard {
                SettingsRow(
                    icon: "nc-trash",
                    title: "Delete account",
                    subtitle: deleteSubtitle
                ) {
                    Button(action: { confirmingDelete = true }) {
                        Text(isDeleting ? "Deleting…" : "Delete account…")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(Theme.Palette.danger)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(
                                Capsule(style: .continuous)
                                    .stroke(Theme.Palette.danger.opacity(0.5), lineWidth: 1)
                            )
                            .opacity(isDeleting ? 0.7 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeleting)
                }
            }
        }
        .alert("Delete your account?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete account", role: .destructive) { delete() }
        } message: {
            Text(
                "This permanently deletes your account and everything in it — every session, transcript, summary, chat and your profile. This can't be undone. Export your data first if you want a copy."
            )
        }
    }

    private var isExporting: Bool {
        export.state == .exporting
    }

    private var exportSubtitle: String {
        switch export.state {
        case .idle, .exporting:
            "Download everything Nod holds about you — every session, transcript, summary, chat, your profile and account data — as one JSON file."
        case .done:
            "Saved. Your data export is a complete, machine-readable copy of everything Nod holds about you."
        case let .failed(message):
            message
        }
    }

    private var deleteSubtitle: String {
        if let deleteError {
            return deleteError
        }
        return "Permanently erase your account and all associated data. Audio is never stored; everything else is deleted within seconds. This can't be undone."
    }

    private func delete() {
        isDeleting = true
        deleteError = nil
        Task {
            do {
                try await auth.deleteAccount()
            } catch {
                deleteError = "Couldn't delete your account. Please try again or email dbarabashdev@gmail.com."
            }
            isDeleting = false
        }
    }
}
