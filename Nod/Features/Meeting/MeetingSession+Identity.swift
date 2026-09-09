import Foundation

/// Which meeting in the world this recording is, and who else is already
/// recording it.
///
/// Split from `MeetingSession` because it answers a question the rest of the
/// session does not care about: the recording behaves identically whether these
/// find anything or not.
extension MeetingSession {
    /// Tells the server which meeting this is, from the calendar on this Mac.
    ///
    /// Only reaches anything when the server could not identify it itself — a
    /// connected Google Calendar is read server-side and always wins. This is
    /// what gives an iCloud or Exchange account, or anyone who never connected
    /// an integration, a place in the same matching.
    func offerCalendarIdentity(_ meetingID: UUID) {
        guard let identity = calendar.currentRoomIdentity() else { return }
        Task { [meetingStore] in
            await meetingStore.offerLeaseIdentity(
                meetingID: meetingID,
                externalID: identity.icalUID,
                conferenceURL: identity.conferenceURL
            )
        }
    }

    /// Asked once, a moment after starting.
    ///
    /// Delayed on purpose: the other person's lease has to exist before it can
    /// be found, and two people pressing Start on the same minute is the case
    /// this is for. Asked once rather than polled — the answer only stops being
    /// useful, and nagging about it later is worse than missing it.
    func askWhoElseIsRecording(_ meetingID: UUID) {
        setConcurrentRecording(nil)
        concurrentCheck?.cancel()
        concurrentCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled, meeting == .recording else { return }
            let found = await meetingStore.concurrentRecording(for: meetingID)
            guard !Task.isCancelled, meeting == .recording else { return }
            if let found {
                Log.ui.info("concurrent recording by \(found.ownerName)")
            }
            setConcurrentRecording(found)
        }
    }
}
