import Foundation

/// The held key: down opens the microphone, up sends what was said. With no
/// meeting running the surface stays at rest — the pill says listening, then
/// thinking, and the card opens only when the answer exists; the voice says
/// it is on it in the meantime, and then says the answer. During a meeting
/// the bar's own Ask box shows the same phases in place.
extension NotchModel {
    func beginVoiceAsk() {
        if demo.isRunning || setup != nil { return }
        // Already an open conversation: the key's only job now is to end it,
        // on release — nothing to start, and its own mic must not collide
        // with a fresh `heldQuestion` capture on the same input device.
        if realtimeVoice.isActive { return }
        switch voicePhase {
        case .idle, .failed: break
        case .listening, .transcribing, .thinking, .speaking: return
        }
        voice.stop()
        voiceAskGeneration += 1
        lastVoiceAskBaseline = nil
        voiceAnswerPending = false
        if hasMeetingBar { showAskSurface() }
        if !audioCapture.isCapturingMicrophone {
            // Read from the system, not from memory: the grant given while the
            // app sat idle was once "not determined" here, and the person was
            // asked to allow a microphone that macOS already allowed.
            permissions.refresh()
            // A denied microphone still opens an engine — one that records
            // silence, which Whisper would happily turn into a question. A
            // never-asked one gets asked; the hold is over by the time the
            // dialog is answered, so the row says what to do next.
            switch permissions.microphone {
            case .authorized:
                break
            case .denied:
                failVoiceAsk("Mic is off in System Settings")
                return
            case .notDetermined:
                setVoiceAsk(.failed("Allow the microphone"))
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let granted = await permissions.requestMicrophone()
                    failVoiceAsk(granted ? "Mic allowed — hold again" : "Mic is off in System Settings")
                }
                return
            }
        }
        do {
            try heldQuestion.start()
        } catch {
            Log.audio.error("held question: could not open the microphone — \(error)")
            failVoiceAsk("Couldn't open the mic")
            return
        }
        setVoiceAsk(.listening)
        voiceHoldLimit = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(HeldQuestionRecorder.maxSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.endVoiceAsk()
        }
    }

    /// The key let go. Held past `HeldQuestionRecorder.minSeconds`, this was a
    /// question — transcribe and answer it as before. Any shorter and it was
    /// a tap: open a live conversation instead, unless a meeting is running
    /// (a live session's own microphone has nowhere safe to sit next to one).
    func endVoiceAsk() {
        if realtimeVoice.isActive {
            realtimeVoice.stop()
            return
        }
        guard voicePhase == .listening else { return }
        voiceHoldLimit?.cancel()
        voiceHoldLimit = nil
        setVoiceAsk(.transcribing)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let wav = await heldQuestion.stop() else {
                setVoiceAsk(.idle)
                guard !hasMeetingBar else { return }
                await realtimeVoice.start(language: voiceLanguage ?? language.current)
                return
            }
            do {
                let heard = try await llmClient.dictate(audio: wav)
                let question = heard.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !question.isEmpty else {
                    failVoiceAsk("Didn't catch that")
                    return
                }
                voiceLanguage = Self.spokenLanguage(heard.language) ?? language.current
                // Where the words go is decided now, not at the press: a
                // meeting that started or ended while the clip was in flight
                // has changed which surface is drawing.
                if hasMeetingBar {
                    voice.acknowledge(question, language: voiceLanguage ?? language.current)
                    setVoiceAsk(.idle)
                    showAskSurface()
                    submitAsk(question, spoken: true)
                } else {
                    await askAtRest(question)
                }
            } catch {
                Log.llm.error("held question: transcription failed — \(error.localizedDescription)")
                failVoiceAsk("Couldn't hear that")
            }
        }
    }

    /// The idle question, answered before anything opens. The thread is the
    /// Library's, as for a typed question; the card is revealed onto the
    /// answer rather than onto an empty field.
    private func askAtRest(_ question: String) async {
        guard !knowledgeChat.isSending else {
            failVoiceAsk("Still answering")
            return
        }
        voice.acknowledge(question, language: voiceLanguage ?? language.current)
        let baseline = knowledgeChat.messages.count
        let generation = voiceAskGeneration
        setVoiceAsk(.thinking)
        // A write the answer wants to make waits on the person, and the card
        // is where they say yes — so it opens the moment one is asked for,
        // answer or no answer yet.
        let approvalWatch = Task { @MainActor [weak self] in
            for await pending in knowledgeChat.toolGate.$pending.values where pending != nil {
                guard let self, generation == voiceAskGeneration, !isAsking else { return }
                setVoiceAsk(.idle)
                revealAsk(baseline: baseline)
                return
            }
        }
        await knowledgeChat.ask(question)
        approvalWatch.cancel()
        let answer = knowledgeChat.answer(after: baseline)
        recordIdleAsk(answered: answer != nil)
        guard generation == voiceAskGeneration else { return }
        guard let answer else {
            failVoiceAsk("Couldn't answer that")
            return
        }
        // The card stays closed on its own: the pill already said the words,
        // and a big panel appearing over whatever the person is doing —
        // unasked — is the interruption they held the key to avoid. Opening
        // it by hand (⌘⇧K, or the launch card) is how they read the rest.
        // `voicePhase` stays `.thinking` — not idle — until the answer is
        // actually spoken; see `voiceAnswerPending`.
        //
        // The one exception: a link. The spoken answer never reads one aloud
        // (`speech.ts`'s persona forbids it), so a voice question that comes
        // back with one has to open on it — otherwise the answer to "what
        // was that link again" is a voice that quietly skipped the link.
        if isAsking || AnswerLinkDetection.containsLink(answer.content) {
            revealAsk(baseline: baseline)
        } else {
            lastVoiceAskBaseline = baseline
        }
        voiceAnswerPending = true
        voice.say(answer.content, asking: question, language: voiceLanguage ?? language.current)
    }

    /// Escape ends a live conversation if one is open, cuts a spoken answer
    /// off if one is playing, or closes the card as it always did.
    func escapeAsk() {
        if realtimeVoice.isActive {
            realtimeVoice.stop()
        } else if speakingWords != nil {
            voice.stop()
            noteSpeaking(nil)
        } else {
            closeAsk()
        }
    }

    /// The live session's own phase, mirrored into the same display the
    /// held-question flow uses — one pill, whichever put it there.
    func noteRealtimeState(_ state: RealtimeVoiceSession.State) {
        switch state {
        case .idle:
            noteSpeaking(nil)
            setVoiceAsk(.idle)
        case .connecting:
            noteSpeaking(nil)
            setVoiceAsk(.thinking)
        case .listening, .userSpeaking:
            noteSpeaking(nil)
            setVoiceAsk(.listening)
        case let .responding(wordsSoFar):
            setVoiceAsk(.thinking)
            noteSpeaking(wordsSoFar)
        case let .failed(reason):
            noteSpeaking(nil)
            failVoiceAsk(reason)
        }
    }

    /// What the voice is saying, so the card's row and the resting pill can
    /// show it — under the question's own phase while there is one.
    func noteSpeaking(_ words: String?) {
        speakingWords = words
        if words == nil, voiceAnswerPending {
            // The answer has now actually been said in full — this is the
            // real end of the exchange, not just a lull between two lines.
            voiceAnswerPending = false
            voicePhase = .idle
        }
        syncVoiceDisplay()
        // The bar's row says "Esc to stop"; that is only true once the panel
        // has the keyboard, which the idle card takes on reveal and the bar
        // never did on its own.
        if words != nil, hasMeetingBar { onWantsKeyboard?() }
    }

    /// Whisper names the language it heard as a code or as a name, depending
    /// on the provider; either is matched against the languages Nod speaks.
    static func spokenLanguage(_ detected: String?) -> AppLanguage? {
        guard let detected = detected?.trimmingCharacters(in: .whitespaces).lowercased(), !detected.isEmpty else { return nil }
        let code = detected.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? detected
        if code.count <= 3, let byCode = AppLanguage(rawValue: code) { return byCode }
        return AppLanguage.allCases.first { language in
            let name = language.promptName.lowercased()
            return name == detected
                || language.nativeName.lowercased() == detected
                || name.split(separator: " ").contains(Substring(detected))
        }
    }

    /// Says why for a moment, then goes back to rest.
    private func failVoiceAsk(_ reason: String) {
        setVoiceAsk(.failed(reason))
        voiceFailureReset?.cancel()
        voiceFailureReset = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled, voicePhase == .failed(reason) else { return }
            setVoiceAsk(.idle)
        }
    }
}
