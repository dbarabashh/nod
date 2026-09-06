import SwiftUI

/// What the two chat transcripts — one session's, and Ask Nod across all of
/// them — do the same way: where the scroll lands, and when an answer may be
/// asked for again.
enum ChatTranscriptSupport {
    /// The rows a transcript scrolls to that are not messages. Separate
    /// identities on purpose: sharing one between the indicator and the
    /// approval card let SwiftUI treat the swap as "same view, unchanged" and
    /// keep the indicator on screen while an approval was already waiting.
    enum Anchor: Hashable {
        case typing
        case approval
        case failure
        case credits
    }

    /// Offered on the newest answer only — regenerating an older one would
    /// orphan every turn written against the answer being replaced.
    static func regenerateAction(isNewest: Bool, isBusy: Bool, _ regenerate: @escaping () -> Void) -> (() -> Void)? {
        guard isNewest, !isBusy else { return nil }
        return regenerate
    }
}

extension ScrollViewProxy {
    /// Mid-stream each flush would restart a 150ms scroll before the last
    /// finished, which is what makes streaming scroll feel rubbery — so a
    /// streaming transcript asks for the jump without the animation.
    func scrollToEnd(_ target: AnyHashable?, animated: Bool = true) {
        guard let target else { return }
        guard animated else {
            scrollTo(target, anchor: .bottom)
            return
        }
        withAnimation(.easeOut(duration: 0.15)) { scrollTo(target, anchor: .bottom) }
    }
}

/// The user's side of a thread: the bubble, and under it whatever the turn
/// has to admit about itself.
struct ChatUserTurn<Notes: View>: View {
    let text: String
    let marks: [MentionMark]
    private let notes: Notes

    init(text: String, marks: [MentionMark], @ViewBuilder notes: () -> Notes) {
        self.text = text
        self.marks = marks
        self.notes = notes()
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            UserTextBubble(text: text, marks: marks)
            notes
        }
        .padding(.leading, 40)
    }
}

#Preview {
    ChatUserTurn(text: "What did I commit to?", marks: []) {
        ChatTurnNotes(isUnsaved: true, storeNoun: "this thread") {}
    }
    .padding(20)
    .frame(width: 420)
    .background(Theme.Palette.bg)
}
