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
    let isOpened: Bool

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

        switch gate {
        case .language: return .languageConfirm
        case .consent: return .consent
        case .allowance: return .alert(.allowance)
        case nil: break
        }

        if let prompt = session.autoEndPrompt {
            return .alert(.autoEnd(prompt))
        }
        if let message = session.saveErrorToast, !session.pendingMeetingSaves.isEmpty {
            return .alert(.saveFailed(message))
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
            // Folds away on the same flag the meeting bar uses, so one swipe
            // means one thing on this surface no matter which side of the
            // meeting you are on.
            return isMeetingBarHidden ? .listeningTucked(joinedRoom) : .listening(joinedRoom, meetingBarPanel)
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
            if meetingBarPanel == .passive {
                Log.ui.debug("notch: showing notice kind=\(notice.kind.rawValue) hidden=\(isMeetingBarHidden)")
                return .noticed(notice)
            }
            // `.debug`, not `.info`: this re-runs on every unrelated publisher
            // tick (meetings sync, entitlement refresh, …) while a notice sits
            // blocked, so it would otherwise repeat well past what `.info` is
            // for.
            Log.ui.debug("notch: notice pending but panel=\(String(describing: meetingBarPanel)) blocks it")
        }
        // Same guard as a notice, and after it: what was just said in this room
        // outranks what was said in another one.
        if let recalled = session.analyst.recall, meetingBarPanel == .passive {
            return .recalled(recalled)
        }
        if isMeetingBarHidden {
            return .tucked
        }
        return .meetingBar(meetingBarPanel)
    }
}
