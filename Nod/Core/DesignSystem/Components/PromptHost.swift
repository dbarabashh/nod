import SwiftUI

/// A window's content with a one-time question over it: while the question is
/// due and has not been waved away this session, the content dims behind a
/// scrim and the prompt sits centred on top.
///
/// The dismissal flag belongs to the caller, whose prompt marks it as part of
/// answering — so what "answered" means (a preference saved, an onboarding
/// flag set) stays beside the prompt that means it.
struct PromptHost<Content: View, Prompt: View>: View {
    let isDue: Bool
    @Binding var isDismissed: Bool
    private let content: Content
    private let prompt: Prompt

    init(
        isDue: Bool,
        isDismissed: Binding<Bool>,
        @ViewBuilder content: () -> Content,
        @ViewBuilder prompt: () -> Prompt
    ) {
        self.isDue = isDue
        _isDismissed = isDismissed
        self.content = content()
        self.prompt = prompt()
    }

    var body: some View {
        ZStack {
            content
            if isDue, !isDismissed {
                Theme.Palette.scrim
                    .ignoresSafeArea()
                prompt
            }
        }
    }
}

#Preview {
    PromptHost(isDue: true, isDismissed: .constant(false)) {
        Theme.Palette.bg
    } prompt: {
        Text("Asked once")
            .padding(40)
            .promptCard(width: 320)
    }
    .frame(width: 600, height: 400)
}
