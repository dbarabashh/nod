import Supabase
import SwiftUI

/// Tells the user this app is being replaced and walks them out of it: export
/// the meetings, get the new Nod, and once the file is saved, erase the cloud
/// copy. Dismissed for the rest of the launch only, so it comes back until the
/// move is done.
struct MigrationBanner: View {
    @EnvironmentObject private var migration: MeetingMigration
    @State private var isConfirmingDelete = false

    var body: some View {
        if !migration.isBannerDismissed {
            banner
                .padding(.horizontal, Theme.Space.x4)
                .padding(.top, Theme.Space.x2)
                .padding(.bottom, Theme.Space.x1)
                .alert("Delete your cloud data and account?", isPresented: $isConfirmingDelete) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete everything", role: .destructive) {
                        Task { await migration.deleteAccount() }
                    }
                } message: {
                    Text(
                        "Export your meetings first. This permanently deletes all your meetings from the cloud, "
                            + "and your Nod account with them. Workspaces and teams you created are handed over to "
                            + "a colleague, or closed if nobody else is in them, and subscriptions you pay for end. "
                            + "This can't be undone."
                    )
                }
        }
    }

    private var banner: some View {
        HStack(alignment: .top, spacing: Theme.Space.x3) {
            Image("nc-bullhorn")
                .icon(14)
                .foregroundStyle(Theme.Palette.brand)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: Theme.Space.x2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This version of Nod is supported until January 31, 2027")
                        .textStyle(Theme.Typography.uiEmphasis)
                        .foregroundStyle(Theme.Palette.ink)
                    Text(
                        "After that it won't get updates or fixes. The good news: the new Nod is here. It writes your "
                            + "notes on your computer, needs no account, and runs on macOS, Windows, and Linux. "
                            + "Export your meetings to a file now, then import it in the new app."
                    )
                    .textStyle(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    if let downloadURL = NewNod.downloadURL {
                        Link(destination: downloadURL) {
                            Text("Download the version for your computer at hellonod.app/download")
                                .textStyle(Theme.Typography.secondary.weight(.semibold))
                                .foregroundStyle(Theme.Palette.brand)
                        }
                        .help(downloadURL.absoluteString)
                    }
                }
                actions
                if let status {
                    Text(status.text)
                        .textStyle(Theme.Typography.meta)
                        .foregroundStyle(status.isError ? Theme.Palette.danger : Theme.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button(action: migration.dismissBanner) {
                Image("nc-xmark")
                    .icon(10)
                    .foregroundStyle(Theme.Palette.muted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide until Nod restarts")
        }
        .padding(Theme.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous)
                .fill(Theme.Palette.brand.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous)
                        .stroke(Theme.Palette.brand.opacity(0.25), lineWidth: 0.5)
                )
        )
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.x2) {
            GlassPillButton(
                "Export meetings",
                size: .compact,
                leadingIcon: "nc-circle-arrow-down",
                isLoading: migration.isExporting
            ) {
                Task { await migration.export() }
            }
            GlassPillButton(
                "Get the new Nod",
                size: .compact,
                trailingIcon: "nc-arrow-up-right",
                tint: .brand,
                action: migration.openDownloadPage
            )
            if migration.hasExported, migration.unsyncedCount == 0 {
                Button {
                    isConfirmingDelete = true
                } label: {
                    Text(migration.isDeleting ? "Deleting…" : "Delete cloud data and account…")
                        .textStyle(Theme.Typography.secondary.weight(.semibold))
                        .foregroundStyle(Theme.Palette.danger)
                        .padding(.horizontal, Theme.Space.x3)
                        .padding(.vertical, Theme.Space.x1)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(migration.isDeleting)
            }
        }
    }

    private var status: (text: String, isError: Bool)? {
        if let deleteError = migration.deleteError {
            return (deleteError, true)
        }
        switch migration.exportState {
        case .idle:
            return nil
        case .fetchingMeetings:
            return ("Collecting your meetings…", false)
        case let .fetchingTranscripts(done, total):
            return ("Collecting transcripts… \(done) of \(total) meetings", false)
        case .saving:
            return ("Choose where to save the file…", false)
        case let .exported(count):
            let noun = count == 1 ? "meeting" : "meetings"
            let unsynced = migration.unsyncedCount
            guard unsynced == 0 else {
                let pending = unsynced == 1 ? "1 meeting hasn't" : "\(unsynced) meetings haven't"
                return (
                    "Exported \(count) \(noun), but \(pending) synced yet and isn't in the file. Keep Nod open until it syncs, then export again.",
                    true
                )
            }
            return ("Exported \(count) \(noun). Import the file in the new Nod. Once it's there, you can delete your cloud data.", false)
        case .outdated:
            return ("Your meetings changed after the export. Export again so the file has all of them.", false)
        case let .failed(message):
            return (message, true)
        }
    }
}

#Preview {
    let supabase = SupabaseClient(supabaseURL: SupabaseConfig.url, supabaseKey: SupabaseConfig.anonKey)
    return MigrationBanner()
        .environmentObject(MeetingMigration(
            supabase: supabase,
            auth: AuthService(client: supabase),
            meetingStore: MeetingStore(supabase: supabase),
            outbox: MeetingOutbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent("preview-outbox"))
        ))
        .frame(width: 720)
        .background(Theme.Palette.bg)
}
