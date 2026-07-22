#if DEBUG
    import Foundation

    extension DemoData {
        static func build() -> Bundle {
            let now = Date()
            let meetings = (coreFixtures + extraFixtures)
                .map { meeting($0, now: now) }
                .sorted { $0.startedAt > $1.startedAt }
            let byID = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })

            let transcripts = demoTranscripts(byID)

            // Only these two demo sessions show a checked-off item; the rest read
            // as freshly captured, still-open work.
            let doneByID: [UUID: Int] = [launchPrep: 1, oneOnOne: 1]
            var actionItems: [UUID: [ActionItem]] = [:]
            for meeting in meetings {
                actionItems[meeting.id] = items(for: meeting, doneCount: doneByID[meeting.id] ?? 0, now: now)
            }

            var chat: [UUID: [ChatMessage]] = [:]
            chat[launchPrep] = [
                message(launchPrep, .user, "What did we decide about the discount code?"),
                message(
                    launchPrep,
                    .assistant,
                    "You didn't decide yet — it was left open. The action item \"Decide on the discount code\" is due before Monday so the launch copy can be finalized."
                )
            ]

            let labels = [
                label(launchLabel, "Product Hunt", "#8B5CF6"),
                label(hiringLabel, "Hiring", "#EC4899"),
                label(oneOnOneLabel, "1:1s", "#22C55E"),
                label(productLabel, "Product", "#3B82F6"),
                label(investorLabel, "Investors", "#F59E0B"),
                label(growthLabel, "Growth", "#14B8A6"),
                label(feedbackLabel, "Feedback", "#EF4444")
            ]
            let assignments: [UUID: Set<UUID>] = [
                launchPrep: [launchLabel],
                designSync: [launchLabel, productLabel],
                oneOnOne: [oneOnOneLabel],
                interview: [hiringLabel],
                roadmapNote: [productLabel],
                investorCall: [investorLabel, launchLabel],
                betaFeedback: [feedbackLabel, productLabel],
                growthReview: [growthLabel, productLabel],
                competitorTeardown: [productLabel, launchLabel]
            ]

            return Bundle(
                meetings: meetings,
                transcripts: transcripts,
                actionItems: actionItems,
                chat: chat,
                labels: labels,
                assignments: assignments
            )
        }

        private static func meeting(_ fixture: Fixture, now: Date) -> Meeting {
            let started = now.addingTimeInterval(-fixture.startedAgo)
            return Meeting(
                id: fixture.id,
                userID: userID,
                createdAt: started,
                startedAt: started,
                endedAt: started.addingTimeInterval(fixture.duration),
                title: fixture.title,
                kind: fixture.kind,
                summary: fixture.recap.toMarkdown(),
                recap: fixture.recap,
                language: "en",
                deletedAt: nil
            )
        }

        private static func items(for meeting: Meeting, doneCount: Int, now: Date) -> [ActionItem] {
            (meeting.recap?.actionItems ?? []).enumerated().map { idx, action in
                let base = ActionItem.new(
                    meetingID: meeting.id,
                    userID: userID,
                    text: action.text,
                    deadline: action.deadline,
                    position: idx
                )
                return idx < doneCount ? base.marked(done: true, at: now) : base
            }
        }

        private static func message(_ meetingID: UUID, _ role: ChatMessage.Role, _ content: String) -> ChatMessage {
            ChatMessage.new(meetingID: meetingID, userID: userID, role: role, content: content)
        }

        private static func label(_ id: UUID, _ name: String, _ color: String) -> SessionLabel {
            SessionLabel(id: id, userID: userID, name: name, color: color, createdAt: nil)
        }
    }
#endif
