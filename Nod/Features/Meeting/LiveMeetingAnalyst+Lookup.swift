import Foundation

/// "Hey Nod, …" — from anybody in the room, answered out of a connected tool.
///
/// The one thing on this surface that is asked for rather than offered, and the
/// machine reflects that at every step: nothing is suppressed for being
/// uninteresting, an empty result is still drawn, and a failure is still drawn.
/// The bar that keeps `notice` and `recall` rare exists because those interrupt
/// somebody mid-sentence. This was the sentence.
///
/// Anybody, deliberately. It is read-only — `MeetingLookup` never shows the
/// model a mutating tool — so no action is taken in anybody's name and the
/// question of whose voice it was does not arise. What does arise is whose data
/// comes back, and that is what `RoomComposition` gates: a tracker read onto a
/// screen being shared with a customer is a disclosure whether or not anything
/// was written.
extension LiveMeetingAnalyst {
    /// Begin watching for the phrase.
    ///
    /// Driven by the transcript landing rather than by a timer. A poll was the
    /// obvious shape and the wrong one: transcription is already the slow part
    /// — the line arrives a second or two after the speaker stops — and a
    /// three-second window on top of that is the difference between Nod
    /// answering and somebody deciding it did not hear them. Scanning costs a
    /// string comparison, so it may as well happen the instant there is
    /// something to scan.
    func startListeningForWake() {
        guard wakeSubscription == nil else { return }
        scannedLines = store.entries.count
        wakeSubscription = store.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scanForWake() }
    }

    func stopListeningForWake() {
        wakeSubscription?.cancel()
        wakeSubscription = nil
        lookupTask?.cancel()
        lookupTask = nil
    }

    /// Read the lines that arrived since the last scan and take the newest
    /// request in them.
    ///
    /// The newest, not the first: somebody who rephrases mid-sentence — "Hey
    /// Nod, what's… Hey Nod, what's the status of the onboarding epic" — means
    /// the second one, and answering the abandoned half is worse than silence.
    func scanForWake() {
        let entries = store.entries
        guard entries.count > scannedLines else { return }
        let fresh = entries[scannedLines...]
        scannedLines = entries.count

        // One at a time. A second request while the first is still resolving
        // replaces it — the room has moved on, and two cards on a floating
        // panel is the ticker this surface refuses to be.
        guard let request = fresh.compactMap({ WakePhrase.request(in: $0.text) }).last else { return }
        ask(request)
    }

    /// Run one spoken request. Public so the panel can offer the same thing as
    /// a button for anybody who would rather not say Nod's name in a meeting.
    func ask(_ request: String) {
        guard let meetingLookup else { return }
        lookupTask?.cancel()

        // Asked before anything is drawn, so a refusal never flashes an answer
        // first. `outsidersPresent` is the default whenever the room cannot be
        // established at all — see `RoomComposition`.
        let room = roomComposition?() ?? .outsidersPresent
        Log.llm.info("live: lookup asked (\(request.count) chars, room=\(room))")
        guard room.mayReadFreely else {
            startLookup(LiveLookup(request: request, provider: nil, state: .refused(.outsidersPresent)))
            settleLookup(.refused(.outsidersPresent))
            return
        }

        startLookup(LiveLookup(request: request, provider: nil))

        lookupTask = Task { [weak self] in
            guard let self else { return }
            let state = await meetingLookup.answer(request)
            guard !Task.isCancelled else { return }
            settleLookup(state)
            Log.llm.info("live: lookup settled \(Self.outcome(of: state))")
        }
    }

    /// What happened, as one word for the log. Never the request and never the
    /// answer: both are the user's meeting, and this line is `.info`.
    private static func outcome(of state: LiveLookup.State) -> String {
        switch state {
        case .resolving: "resolving"
        case .answered: "answered"
        case .empty: "empty"
        case .failed: "failed"
        case let .refused(why):
            switch why {
            case .outsidersPresent: "refused-outsiders"
            case .noProvider: "refused-no-provider"
            }
        }
    }
}
