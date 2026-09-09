import SwiftUI

/// Logs what a meeting produced onto a CRM record, picked by name.
///
/// The record is searched and chosen here, never guessed: a note on the wrong
/// contact is worse than no note, and the server refuses an id whose live
/// name differs from the one shown (`assertRecordNamed`). The search is a
/// read of a connected tool and spends a credit like any other.
struct CRMNoteForm: View {
    struct Record: Identifiable, Equatable, Decodable {
        let id: String
        var name: String?
        var email: String?
        var company: String?

        var display: String {
            name?.nilIfBlank ?? email ?? id
        }
    }

    let item: ActionItem
    let crm: IntegrationProvider
    let initialBody: String
    let onDone: (_ record: String, _ url: URL?) -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var integrations: IntegrationService

    @State private var query = ""
    @State private var results: [Record] = []
    @State private var picked: Record?
    @State private var note = ""
    @State private var isSearching = false
    @State private var isSending = false
    @State private var sendError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InlineFormHeader("Log a note", provider: crm, dismissTitle: "Cancel", onDismiss: onCancel)
            if let picked {
                HStack(spacing: 6) {
                    OrgMonogram(name: picked.display, size: 18)
                    Text(picked.display)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.ink)
                    if let company = picked.company {
                        Text(company)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.Palette.muted)
                    }
                    Spacer(minLength: 0)
                    Button("Change") { self.picked = nil }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.muted)
                        .linkCursor()
                }
            } else {
                InlineTextField("Who is this about? Search contacts", text: $query)
                    .onSubmit { Task { await search() } }
                if isSearching {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Searching \(crm.displayName)…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.Palette.muted)
                    }
                }
                ForEach(results) { record in
                    Button { picked = record } label: {
                        HStack(spacing: 6) {
                            Text(record.display)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.Palette.ink)
                            Text([record.company, record.email].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.Palette.muted)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .linkCursor()
                }
            }
            InlineTextEditor(text: $note, minHeight: 72)
            if let sendError {
                Text(sendError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer(minLength: 0)
                GlassPillButton(isSending ? "Logging…" : "Log note", size: .compact) {
                    Task { await send() }
                }
                .disabled(picked == nil || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
        }
        .onAppear { if note.isEmpty { note = initialBody } }
    }

    private func search() async {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, !isSearching else { return }
        isSearching = true
        defer { isSearching = false }
        let raw = await integrations.run(
            ActionDelegation.call(action: "find_contact", of: crm, arguments: ["query": typed]),
            tool: ActionDelegation.tool(action: "find_contact", of: crm),
            origin: .app
        )
        if let failure = IntegrationService.failure(in: raw) {
            sendError = IntegrationService.failureCode(in: raw) == IntegrationService.creditsExhaustedCode
                ? "Out of integration credits for this month — searching \(crm.displayName) is paused."
                : failure
            return
        }
        results = Self.contacts(in: raw)
        sendError = results.isEmpty ? "Nobody in \(crm.displayName) matches “\(typed)”." : nil
    }

    static func contacts(in raw: String) -> [Record] {
        struct Envelope: Decodable {
            struct Payload: Decodable { let contacts: [Record] }
            let result: Payload?
        }
        guard let data = raw.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return [] }
        return envelope.result?.contacts ?? []
    }

    private func send() async {
        guard let picked, !isSending else { return }
        isSending = true
        sendError = nil
        let raw = await integrations.run(
            ActionDelegation.call(
                action: "create_note",
                of: crm,
                arguments: [
                    "attach_to": "contact",
                    "record_id": picked.id,
                    "record_name": picked.display,
                    "body": note.trimmingCharacters(in: .whitespacesAndNewlines)
                ]
            ),
            tool: ActionDelegation.tool(action: "create_note", of: crm),
            origin: .app
        )
        isSending = false
        if let failure = IntegrationService.failure(in: raw) {
            sendError = failure
            return
        }
        onDone("Note on \(picked.display) in \(crm.displayName)", Self.url(in: raw))
    }

    static func url(in raw: String) -> URL? {
        struct Envelope: Decodable {
            struct Payload: Decodable { let attached_to: String? }
            let result: Payload?
        }
        guard let data = raw.data(using: .utf8),
              let url = try? JSONDecoder().decode(Envelope.self, from: data).result?.attached_to else { return nil }
        return URL(string: url)
    }
}
