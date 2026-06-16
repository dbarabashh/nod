import SwiftUI

struct ResponseCard: View {
    let kind: String
    let text: String
    let onCopy: (String) -> Void
    let onDismiss: () -> Void
    /// (currentText, instruction) → updated text. Wired in ContentView via
    /// PromptLibrary.buildSummaryEdit + llm.complete.
    var onAIEdit: ((String, String) async throws -> String)?

    /// Working buffer the TextEditor binds to. Seeded from `text` and kept in
    /// sync if a fresh response arrives (e.g. switching from "Catch me up" to
    /// "Meeting recap" without dismissing the card).
    @State private var editableText: String = ""
    @State private var aiInstruction: String = ""
    @State private var isApplyingEdit: Bool = false
    @State private var editError: String?
    @FocusState private var instructionFocused: Bool
    /// True when the editable recap is shown as rendered markdown; false
    /// when the user has tapped Edit to switch to the raw TextEditor.
    /// Defaults to true so the user sees `**Topics covered**` as bold
    /// instead of literal asterisks the moment the recap lands.
    @State private var isPreviewingRecap: Bool = true

    /// Edit affordances are only enabled for the end-of-meeting recap. Mid-call
    /// cards ("Catch me up", "Key points", …) are read-only — they're
    /// ephemeral and editing them adds noise without value. Caller signals
    /// "this card is persistent + editable" by passing `onAIEdit`.
    private var isEditable: Bool {
        onAIEdit != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(red: 0.62, green: 0.82, blue: 1.0))
                Text(kindLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                if isEditable {
                    Button(action: { isPreviewingRecap.toggle() }) {
                        Image(systemName: isPreviewingRecap ? "square.and.pencil" : "eye")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.65))
                            .frame(width: 22, height: 18)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help(isPreviewingRecap ? "Edit raw markdown" : "Preview formatted")
                    .disabled(isApplyingEdit)
                }
                Button(action: {
                    print("→ Dismiss response")
                    onDismiss()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            if isEditable {
                // Editable buffer with view / edit toggle. Default view
                // renders markdown so `**Topics covered**` is bold. Tap
                // the pencil icon up top to flip to raw TextEditor for
                // direct edits; "eye" icon flips back. The AI-edit input
                // below works in either mode and updates the same buffer.
                //
                // Editor is disabled while an AI edit is in flight so
                // user keystrokes can't race the async response —
                // without this the LLM's returned text would silently
                // overwrite anything they typed during the await.
                Group {
                    if isPreviewingRecap {
                        ScrollView(.vertical, showsIndicators: true) {
                            Text(renderRecapMarkdown(editableText))
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(.white.opacity(0.92))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        }
                    } else {
                        TextEditor(text: $editableText)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.white.opacity(0.92))
                            .scrollContentBackground(.hidden)
                    }
                }
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(minHeight: 180, maxHeight: 320)
                .disabled(isApplyingEdit && !isPreviewingRecap)
                .opacity(isApplyingEdit ? 0.6 : 1.0)

                if let editError {
                    Text(editError)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(Color(red: 0.95, green: 0.55, blue: 0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }

                aiEditRow
            } else {
                // Mid-call responses ("Catch me up", "Key points", …) are
                // ephemeral — read-only rendered markdown. Wrapped in a
                // bounded ScrollView so long replies stay scrollable inside
                // the card instead of overflowing the floating panel.
                ScrollView(.vertical, showsIndicators: true) {
                    Text(renderRecapMarkdown(editableText))
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 320)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                MiniAction(label: "Copy", icon: "doc.on.doc") {
                    onCopy(editableText)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                PanelMaterial()
                Color.black.opacity(0.18)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        .shadow(color: Color.black.opacity(0.30), radius: 12, x: 0, y: 6)
        .onAppear {
            // Seed the editor with whatever the LLM just produced. Subsequent
            // user edits live in @State and aren't overwritten unless a brand
            // new response arrives.
            if editableText.isEmpty { editableText = text }
        }
        .onChange(of: text) { new in
            // A fresh LLM response landed (e.g. user re-asked) — sync the
            // editor buffer to the new source text. Leave `aiInstruction` and
            // `editError` alone: if the user was mid-typing an instruction
            // when an unrelated parent rebuild flowed a (possibly identical)
            // text through, wiping their input is silent data loss.
            // (macOS 13 onChange signature — single closure arg.)
            editableText = new
        }
    }

    /// Chat-style input row: type instruction, ⏎ or send button to apply.
    private var aiEditRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))

            TextField("Ask AI to edit…", text: $aiInstruction, axis: .horizontal)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.white.opacity(0.92))
                .focused($instructionFocused)
                .disabled(isApplyingEdit)
                .onSubmit(applyAIEdit)

            Button(action: applyAIEdit) {
                if isApplyingEdit {
                    ProgressView()
                        .controlSize(.mini)
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(canSubmitEdit ? Color(red: 0.62, green: 0.82, blue: 1.0) : .white.opacity(0.25))
                }
            }
            .buttonStyle(.plain)
            .disabled(!canSubmitEdit)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private var canSubmitEdit: Bool {
        !isApplyingEdit
            && !aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && onAIEdit != nil
    }

    private func applyAIEdit() {
        guard canSubmitEdit, let onAIEdit else { return }
        let snapshot = editableText
        let instruction = aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        isApplyingEdit = true
        editError = nil
        Task {
            do {
                let updated = try await onAIEdit(snapshot, instruction)
                await MainActor.run {
                    editableText = updated
                    aiInstruction = ""
                    isApplyingEdit = false
                }
            } catch {
                await MainActor.run {
                    editError = "Edit failed: \(error.localizedDescription)"
                    isApplyingEdit = false
                }
            }
        }
    }

    private var kindLabel: String {
        switch kind {
        case "hero": "Catch me up"
        case "Meeting Summary": "Meeting recap"
        default: kind
        }
    }
}

struct MiniAction: View {
    let label: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
    }
}
