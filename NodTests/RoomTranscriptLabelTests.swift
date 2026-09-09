import XCTest
@testable import Nod

/// A room recording is the iOS companion's shape: one microphone, everyone on
/// it, the person holding the phone included. The Mac has to read those rows
/// without mistaking whose words they are — and without changing what it says
/// about the two streams it records itself.
///
/// These pin the room half; `TranscriptLabelTests` pins the two routed
/// streams. A room line rendered as "Me" attributes a room full of people to
/// the user, and the failure is silent.
final class RoomTranscriptLabelTests: XCTestCase {
    private func record(source: String, speaker: Int?) -> TranscriptRecord {
        TranscriptRecord(
            id: UUID(),
            meetingID: UUID(),
            userID: UUID(),
            createdAt: nil,
            source: source,
            text: "we should ship it",
            ts: Date(),
            idx: 0,
            speaker: speaker
        )
    }

    func testHostStillNarrowsTheUsersOwnMic() {
        XCTAssertEqual(record(source: "me", speaker: nil).displayLabel(host: "Dima"), "Dima")
    }

    // MARK: - A room line is answered by its cluster, never by its tag

    func testRoomLineWithoutDiarizationIsNeutral() {
        // Not "Me": nothing here says the person holding the phone is speaking.
        XCTAssertEqual(record(source: "room", speaker: nil).displayLabel(), "Speaker")
    }

    func testRoomLineUsesTheClusterName() {
        XCTAssertEqual(
            record(source: "room", speaker: 2).displayLabel(names: ["2": "Eric"], selfSpeaker: 1),
            "Eric"
        )
    }

    func testRoomLineFallsBackToTheClusterNumber() {
        XCTAssertEqual(record(source: "room", speaker: 3).displayLabel(selfSpeaker: 1), "Speaker 3")
    }

    func testTheSelfClusterIsTheUser() {
        XCTAssertEqual(record(source: "room", speaker: 1).displayLabel(selfSpeaker: 1), "Me")
        XCTAssertEqual(
            record(source: "room", speaker: 1).displayLabel(host: "Dima", selfSpeaker: 1),
            "Dima"
        )
    }

    func testSelfClusterOnlyAppliesToRoomRecordings() {
        // A cluster number on the remote stream is a remote voice, whatever the
        // session's self speaker happens to be.
        XCTAssertEqual(
            record(source: "them", speaker: 1).displayLabel(names: ["1": "Eric"], selfSpeaker: 1),
            "Eric"
        )
    }

    // MARK: - Prompts keep the vocabulary their rules key on

    func testRoomLinesMapOntoMeAndThemForPrompts() {
        XCTAssertEqual(record(source: "room", speaker: 1).promptLabel(selfSpeaker: 1), "Me")
        XCTAssertEqual(
            record(source: "room", speaker: 2).promptLabel(names: ["2": "Eric"], selfSpeaker: 1),
            "Them · Eric"
        )
        XCTAssertEqual(record(source: "room", speaker: nil).promptLabel(), "Speaker")
    }

    func testSpeakerNameForExcerptsFollowsTheSameRule() {
        XCTAssertEqual(record(source: "room", speaker: 1).speakerName(from: [:], selfSpeaker: 1), "Me")
        XCTAssertEqual(
            record(source: "room", speaker: 2).speakerName(from: ["2": "Eric"], selfSpeaker: 1),
            "Eric"
        )
        XCTAssertEqual(record(source: "me", speaker: nil).speakerName(from: [:]), "Me")
    }

    // MARK: - Rows written before any of this existed still decode

    func testMeetingWithoutSelfSpeakerDecodes() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "user_id": "\(UUID().uuidString)",
          "started_at": "2026-08-01T10:00:00Z",
          "ended_at": "2026-08-01T10:30:00Z",
          "kind": "meeting",
          "summary": "",
          "language": "en"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meeting = try decoder.decode(Meeting.self, from: Data(json.utf8))
        XCTAssertNil(meeting.selfSpeaker)
    }
}
