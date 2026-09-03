import Foundation

/// Which of the notch's states the world currently warrants.
///
/// Its own type because it is its own decision. Inside `NotchModel` this was a
/// function that grew a branch every time the surface learned to say something
/// new, sitting in a class that also owns the panel, the Ask box, and the
/// window notifications — so a change to what outranks what had to be made
/// inside four hundred lines of unrelated behaviour.
///
/// A value with no state of its own: every input is handed in, so the ordering
/// below is the whole thing, readable top to bottom.
@MainActor
struct NotchStateResolver {
    let demoStage: DemoStage?
    let isUpdateRequired: Bool
    /// The onboarding half the notch runs, while it is running.
    let setup: NotchSetupStage?
    let gate: NotchModel.Gate?
    let session: MeetingSession
    let offer: MeetingOffer?
    /// A colleague already recording the meeting this account is in.
    let liveRoom: LiveRoom?
    /// The room this account has actually joined.
    let joinedRoom: JoinedRoom?
    let meetingBarPanel: MeetingBarPanel
    let isMeetingBarHidden: Bool
    let recap: RecapState?
    /// The person opened the surface to ask something, not to record.
    let isAsking: Bool
    let isOpened: Bool
    /// A question being spoken or answered by voice, with nothing to draw it
    /// in: the resting pill shows the phase until the answer opens the card.
    let voiceAsk: VoiceAskPhase

    /// Priority order, most urgent first. A gate outranks everything because it
    /// is the user's own half-finished action; an alert outranks the ambient
    /// states because ignoring it ends or loses a recording.
    func resolve() -> NotchPresentation {
        // The demo owns the surface outright while it runs — it is a recording
        // of a scripted story, and a real alert cutting into it would ruin the
        // take.
        if let demoStage {
            return .demo(demoStage)
        }

        if isUpdateRequired {
            return .updateRequired
        }

        // Nothing below can start until the setup has asked for it, and a
        // stray offer over the permissions card would be the surface
        // interrupting its own introduction.
        if let setup {
            return .setup(setup)
        }

        switch gate {
        case .language: return .languageConfirm
        case .consent: return .consent
        case .allowance: return .alert(.allowance)
        case .systemAudioAccess: return .systemAudioAccess
        case nil: break
        }

        if let prompt = session.autoEndPrompt {
            return .alert(.autoEnd(prompt))
        }
        if let message = session.saveErrorToast, !session.pendingMeetingSaves.isEmpty {
            return .alert(.saveFailed(message))
        }
        // The person is mid-sentence to Nod. Nothing that arrives on its own —
        // a room, an offer, a card — outranks that; a running meeting's bar
        // draws the same phases itself, so this is only for the surface at rest.
        // Speaking with the card open is the card's own row; speaking after the
        // card was closed is the pill again, so what is being said stays on
        // screen until Escape.
        if voiceAsk != .idle, session.meeting == .idle, joinedRoom == nil, !(isAsking && voiceAsk.isSpeaking) {
            return .voice(voiceAsk)
        }
        // Above the offer, and this is a reversal. The ordering used to put
        // "shall I record this?" first, reasoning that a colleague recording is
        // a reason to join rather than a reason not to be asked. True — but both
        // arrive on the same calendar entry at the same second, so the offer
        // simply hid the room for its whole life and the second person was never
        // told anybody had started. What they saw instead was an invitation to
        // record the same meeting a second time.
        //
        // So the room leads and the offer rides along: `alsoOffered` keeps
        // "record it myself" one press away, which is what the old ordering was
        // actually protecting.
        if session.meeting == .idle, let liveRoom {
            return .liveRoom(liveRoom, alsoOffered: offer != nil)
        }
        if let offer {
            return .offer(offer)
        }
        if session.meeting != .idle {
            return recording()
        }
        // Above everything below, because you cannot be offered a room you are
        // already in — and above the recap, because what is being said now
        // outranks what a finished meeting amounted to.
        if let joinedRoom {
            // The same two states the recording side resolves to, through the
            // same flag: one swipe means one thing on this surface no matter
            // which side of the meeting you are on.
            return bar(.listening(joinedRoom))
        }
        // Above the recap: the person just asked for the box, and a card that
        // arrived on its own does not outrank what they pressed a key for.
        if isAsking {
            return .ask
        }
        if let recap {
            return .recap(recap)
        }
        return isOpened ? .launch : .dormant
    }

    /// What the surface says while a recording runs.
    private func recording() -> NotchPresentation {
        // A notice surfaces even over a swipe-hidden bar — the whole point of a
        // notice is that it says something the user did not ask for, and a swipe
        // from ten minutes ago is not them declining to hear it. Never over an
        // expanded panel, though: Ask/Notes are open because the user opened
        // them, and taking that away to say something they did not ask for is
        // the difference between proactive and rude.
        if let notice = session.analyst.notice {
            if meetingBarPanel.expansion == .passive {
                Log.ui.debug("notch: showing notice kind=\(notice.kind.rawValue) hidden=\(isMeetingBarHidden)")
                return .noticed(notice)
            }
            // `.debug`, not `.info`: this re-runs on every unrelated publisher
            // tick (meetings sync, entitlement refresh, …) while a notice sits
            // blocked, so it would otherwise repeat well past what `.info` is
            // for.
            Log.ui.debug("notch: notice pending but panel=\(String(describing: meetingBarPanel.expansion)) blocks it")
        }
        // Same guard as a notice, and after it: what was just said in this room
        // outranks what was said in another one.
        if let recalled = session.analyst.recall, meetingBarPanel.expansion == .passive {
            return .recalled(recalled)
        }
        return bar(.host)
    }

    /// Tucked or expanded, for whichever side of the meeting is asking. The
    /// swipe-away flag is deliberately shared: it is the user saying "out of the
    /// way", and that means the same thing in both rooms.
    private func bar(_ role: MeetingBarRole) -> NotchPresentation {
        isMeetingBarHidden ? .tucked(role) : .meetingBar(role, meetingBarPanel)
    }
}
