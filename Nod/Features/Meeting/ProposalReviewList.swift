import SwiftUI

/// What the meeting is offering to do, waiting on an answer.
///
/// Shown under the recap rather than as a dialog when the meeting ends. A modal
/// arrives while the user is still standing up from the call, and a decision
/// taken to dismiss a modal is not a decision — it is the reflex this whole
/// confirm-before-acting design exists to avoid.
///
/// Draws nothing at all when there is nothing outstanding, which is every
/// meeting for a user who has connected no tracker.
struct ProposalReviewList: View {
    let meetingID: UUID

    @EnvironmentObject private var proposals: ActionProposalStore

    /// Everything this meeting still owes an answer or an attempt — including
    /// what was approved and never ran, which is the state a crash between the
    /// two leaves behind and the only one nothing else would ever surface.
    private var outstanding: [ActionProposal] {
        proposals.proposals(forMeeting: meetingID)
            .filter { ActionProposal.Status.unsettled.contains($0.status) }
    }

    var body: some View {
        if !outstanding.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                header
                ForEach(outstanding) { proposal in
                    ProposalReviewCard(proposal: proposal)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 18)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Ready to file")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text("\(outstanding.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.muted)
        }
    }
}

/// One proposal, and the two answers it can be given.
///
/// The title is editable in place. A ticket is read by somebody with none of the
/// meeting in their head, and the person approving is the only one who has both
/// — asking them to accept or reject a sentence they cannot fix would make
/// "reject" the answer to a wording problem.
struct ProposalReviewCard: View {
    let proposal: ActionProposal

    @EnvironmentObject private var proposals: ActionProposalStore
    @EnvironmentObject private var organizations: OrganizationService
    @State private var title: String = ""
    @State private var isDeciding = false

    /// Who this can be handed to: everybody the organization knows about,
    /// reachable in the product this proposal targets. Somebody Nod cannot find
    /// there is not an assignee — offering them would only move the failure to
    /// after the approval.
    private var candidates: [Person] {
        guard let provider = proposal.provider else { return [] }
        return organizations.people.filter { $0.isReachable(in: provider) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let provider = proposal.provider {
                    Image(provider.iconName)
                        .icon(13)
                        .foregroundStyle(Theme.Palette.muted)
                }
                TextField("Task title", text: $title)
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink)
                    .onSubmit { decide(approve: true) }
            }
            detail
            actions
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .onAppear { title = proposal.headline }
        .opacity(isDeciding ? 0.5 : 1)
        .disabled(isDeciding)
    }

    /// Who this is for, or the question that stands in for an answer.
    ///
    /// Never a percentage. A number reads as a precision the measurement does
    /// not have, and nobody has ever acted differently on 0.74 than on 0.68.
    @ViewBuilder
    private var detail: some View {
        if let assignee = proposal.parameters["assignee_name"] {
            Text("For \(assignee)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.muted)
        } else if let hint = proposal.parameters["assignee_hint"] {
            // The name as it was said, still unresolved — and a way to resolve
            // it, because a warning the user cannot act on is just a worse
            // version of saying nothing.
            Menu {
                ForEach(candidates) { person in
                    Button(person.name) { assign(person) }
                }
                if candidates.isEmpty {
                    Text("Nobody in your connected tools matches")
                }
            } label: {
                Label("Who is \(hint)?", image: "nc-triangle-warning")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.warning)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch proposal.status {
        case .executing:
            HStack(spacing: 6) {
                ProgressView().progressViewStyle(.circular).controlSize(.small)
                Text("Filing…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.muted)
            }
        case .approved, .failed:
            // Approved and not filed. Retrying is the only sensible offer: the
            // decision has already been taken and taking it again would be
            // asking the same question twice.
            HStack(spacing: 8) {
                Button("Try again") { Task { await proposals.execute(proposal) } }
                    .controlSize(.small)
                if let failure = proposal.failureMessage {
                    Text(failure)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.warning)
                        .lineLimit(2)
                }
                Spacer()
            }
        default:
            HStack(spacing: 8) {
                // No `.keyboardShortcut(.defaultAction)`. A meeting produces
                // several of these at once, and every card claiming Return
                // leaves which one it presses undefined. Submitting the title
                // field approves that card, which is unambiguous because only
                // one field has focus.
                Button("Approve") { decide(approve: true) }
                    .controlSize(.small)
                Button("Dismiss") { decide(approve: false) }
                    .controlSize(.small)
                Spacer()
            }
        }
    }

    /// Naming the owner is an edit, not an approval. The person may still want
    /// to change the title, or decide the task should not exist — answering one
    /// question should not commit them to the rest.
    private func assign(_ person: Person) {
        guard !isDeciding else { return }
        var parameters = proposal.parameters
        parameters["assignee_person_id"] = person.personID.uuidString
        parameters["assignee_name"] = person.name
        parameters.removeValue(forKey: "assignee_hint")
        isDeciding = true
        Task {
            defer { isDeciding = false }
            _ = await proposals.assign(proposal, parameters: parameters)
        }
    }

    private func decide(approve: Bool) {
        guard !isDeciding else { return }
        isDeciding = true
        Task {
            defer { isDeciding = false }
            let edited = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if approve {
                var parameters = proposal.parameters
                if !edited.isEmpty { parameters["title"] = edited }
                // Approving is what the user asked for; running it is what they
                // meant. They are two calls because they fail differently, and
                // the second one leaves its own trail whatever it does.
                guard await proposals.approve(proposal, parameters: parameters) else { return }
                await proposals.execute(proposal)
            } else {
                _ = await proposals.reject(proposal)
            }
        }
    }
}

#if DEBUG
    #Preview("Nothing outstanding") {
        ProposalReviewList(meetingID: UUID())
            .environmentObject(ActionProposalStore(supabase: nil))
            .padding()
            .frame(width: 420)
    }
#endif
