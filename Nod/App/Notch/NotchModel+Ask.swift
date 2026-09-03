import Foundation

/// The idle Ask box: the hotkey's question with no meeting running, answered
/// out of the sessions, the calendar and what has been on screen. The thread
/// is `KnowledgeChatStore`'s — the same one the Library dock shows — so a
/// question asked here can be picked up there.
extension NotchModel {
    func openAsk() {
        guard !isAsking else { return }
        isAsking = true
        isOpened = true
        // A voice question that hasn't been superseded by anything since is
        // what "open Ask" means right after one: the field would otherwise
        // be blank over an answer the person just heard and wants to reread.
        if let lastVoiceAskBaseline, knowledgeChat.messages.count > lastVoiceAskBaseline {
            askBaseline = lastVoiceAskBaseline
        } else {
            askBaseline = knowledgeChat.messages.count
        }
        lastVoiceAskBaseline = nil
        session.analyst.dismissNotice()
        session.analyst.dismissRecall()
        refresh()
        onWantsKeyboard?()
    }

    /// The card, opened onto an answer that already exists: a spoken question
    /// is answered with the surface at rest, and this is the moment the text
    /// arrives. `baseline` is the thread's length before that question, so the
    /// answer to it is what the card shows.
    func revealAsk(baseline: Int) {
        isAsking = true
        isOpened = true
        askBaseline = baseline
        session.analyst.dismissNotice()
        session.analyst.dismissRecall()
        refresh()
        onWantsKeyboard?()
    }

    func closeAsk() {
        guard isAsking else { return }
        isAsking = false
        isOpened = false
        refresh()
    }

    /// The question, sent. Blank input is a no-op rather than a round trip that
    /// would come back empty. The store refuses a second question while one is
    /// in flight, so this never runs two.
    func submitIdleAsk(_ question: String) {
        submitIdleAsk(question, spoken: false)
    }

    /// `spoken` is a question that came in by voice, so the answer goes back
    /// out the same way.
    func submitIdleAsk(_ question: String, spoken: Bool) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let baseline = knowledgeChat.messages.count
            await knowledgeChat.ask(trimmed)
            let answer = knowledgeChat.answer(after: baseline)
            if spoken, let answer { voice.say(answer.content, asking: trimmed, language: voiceLanguage ?? language.current) }
            recordIdleAsk(answered: answer != nil)
            refresh()
        }
    }

    func recordIdleAsk(answered: Bool) {
        analytics.record(
            .aiActionCompleted,
            properties: .init(
                entryPoint: .hotkey,
                surface: .ask,
                contentType: .answer,
                aiFeature: .knowledgeAsk,
                outcome: answered ? .success : .failure
            )
        )
    }

    /// An evidence row, clicked: the session opens in the main window and the
    /// box folds away, since the answer has moved somewhere with more room.
    func openMeetingFromAsk(_ id: UUID) {
        closeAsk()
        NotificationCenter.default.post(
            name: .nodOpenMeetingDetail,
            object: nil,
            userInfo: [Notification.nodMeetingIDKey: id]
        )
    }

    /// Hands the thread to the Library — same store, same saved thread, so the
    /// conversation continues rather than restarting.
    func openLibraryFromAsk() {
        closeAsk()
        NotificationCenter.default.post(name: .nodOpenLibrary, object: nil)
        NotificationCenter.default.post(name: .nodOpenKnowledgeChats, object: nil)
    }
}
