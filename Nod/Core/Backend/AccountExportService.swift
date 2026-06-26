import AppKit
import Foundation
import Supabase

/// GDPR Right of Access & Data Portability (Art. 15 / 20). Asks the
/// `export-account` Edge Function for the signed-in user's complete personal
/// data as one JSON document, then lets the user save it to disk. The whole
/// payload is assembled server-side (so the schema lives in one place); the app
/// just receives the bytes and writes them where the user chooses.
@MainActor
final class AccountExportService: ObservableObject {
    enum State: Equatable {
        case idle, exporting, done, failed(String)
    }

    @Published private(set) var state: State = .idle

    private let supabase: SupabaseClient

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    func export() async {
        guard state != .exporting else { return }
        state = .exporting
        do {
            let data: Data = try await supabase.functions.invoke(
                "export-account",
                decode: { data, _ in data }
            )
            guard let url = presentSavePanel() else {
                state = .idle
                return
            }
            try data.write(to: url, options: .atomic)
            Log.ui.info("AccountExportService wrote \(data.count) bytes to \(url.lastPathComponent)")
            state = .done
        } catch {
            Log.ui.error("AccountExportService.export failed: \(error.localizedDescription)")
            state = .failed("Couldn't export your data. Please try again.")
        }
    }

    private func presentSavePanel() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export your Nod data"
        panel.nameFieldStringValue = "nod-data-export.json"
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
