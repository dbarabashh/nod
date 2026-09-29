import SwiftUI

struct MeetingMemoryPrompt: View {
    let meeting: Meeting
    var acrossMeetings = false
    @EnvironmentObject private var chat: KnowledgeChatStore
    @EnvironmentObject private var entitlements: EntitlementService

    var body: some View {
        if !meeting.isWelcome, !meeting.summary.isEmpty, entitlements.can(.askAcrossMeetings) {
            SecondaryPillButton(acrossMeetings ? "Find related decisions in my meetings" : "Ask Nod what to do next") {
                guard !chat.isSending else { return }
                let source = KnowledgeChatStore.SessionRef(
                    id: meeting.id, title: meeting.displayTitle(dateFormatter: Meeting.shortDateFormatter)
                )
                chat.startNewThread()
                chat.pendingMentions = acrossMeetings ? [] : [source]
                chat.sendsPendingDraftImmediately = true
                chat.pendingDraft = acrossMeetings
                    ? "Find decisions in my other meetings related to the session titled \"\(source.title)\". Show the sources."
                    : "What should I do next after \(source.mentionToken)? Use the session and show the sources."
                NotificationCenter.default.post(name: .nodOpenKnowledgeChats, object: nil)
            }
            .disabled(chat.isSending)
        }
    }
}
