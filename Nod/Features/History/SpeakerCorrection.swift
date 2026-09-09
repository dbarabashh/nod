import SwiftUI

/// The chip above a line of transcript, with "who was this" attached.
///
/// A menu on the chip rather than a prompt after the meeting, because the
/// question is only answerable while looking at what was said — "Speaker 3 said
/// 'I'll talk to Legal tomorrow'" is the context that makes the answer obvious,
/// and a list of clusters in a settings pane is not.
///
/// Two ways to answer, and both matter. Inside an organization there are
/// colleagues to pick, and picking one is what makes the speaker somebody Nod
/// can later assign work to. On a personal account there are none — and typing
/// the name is still worth it, because a transcript that says "Anna" reads
/// correctly and a summary written from it names her. Withholding that from
/// everybody outside a company would make the feature useless for most people
/// who have one.
///
/// No checkmark marks the current choice — the chip is showing it. A menu that
/// also ticked it would be saying the same thing twice in less room.
struct SpeakerCorrectionChip: View {
    let label: String
    let tint: Color
    let isResolving: Bool
    let cluster: Int
    let people: [Person]
    /// Whether this cluster currently carries a name, which decides if there is
    /// anything to clear.
    let isNamed: Bool
    /// A person when one was picked, and a bare name when it was typed.
    let onConfirm: (Person?, String?) -> Void

    @State private var isNaming = false
    @State private var typedName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        Menu {
            ForEach(people) { person in
                Button(person.name) { onConfirm(person, nil) }
            }
            if !people.isEmpty {
                Divider()
            }
            Button(people.isEmpty ? "Set a name…" : "Someone else…") { beginNaming() }
            if isNamed {
                Button("Not identified") { onConfirm(nil, nil) }
            }
        } label: {
            SpeakerChip(label: label, tint: tint, isResolving: isResolving)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Who was speaking?")
        .accessibilityLabel("Speaker \(cluster): \(label). Choose who was speaking.")
        .popover(isPresented: $isNaming, arrowEdge: .bottom) {
            naming
        }
    }

    private var naming: some View {
        HStack(spacing: 6) {
            TextField("Name", text: $typedName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 160)
                .focused($nameFocused)
                .onSubmit { commitTypedName() }
            Button("Save") { commitTypedName() }
                .controlSize(.small)
                .disabled(typedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
        .onAppear { nameFocused = true }
    }

    private func beginNaming() {
        typedName = ""
        isNaming = true
    }

    private func commitTypedName() {
        let name = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isNaming = false
        onConfirm(nil, name)
    }
}

#if DEBUG
    #Preview("Speaker correction") {
        SpeakerCorrectionChip(
            label: "Speaker 2",
            tint: Theme.Palette.cyan.opacity(0.18),
            isResolving: false,
            cluster: 2,
            people: [],
            isNamed: false,
            onConfirm: { _, _ in }
        )
        .padding()
    }
#endif
