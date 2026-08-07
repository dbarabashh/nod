import Foundation

// MARK: - Recruiting

extension DemoScenario {
    static let recruitingBeats: [DemoBeat] = [
        .init(at: 3.2, action: .stage(.transcript("She walked through the migration really clearly."))),
        .init(at: 6.2, action: .stage(.transcript("Has anyone else interviewed her for this loop?"))),

        .init(at: 8.8, action: .stage(.searching("Checking interview history"))),
        .init(at: 10.0, action: .stage(.context(DemoContext(
            lead: "Two earlier interviewers left notes — and they land on the same strength.",
            sources: [
                DemoSource(
                    tool: .notion,
                    reference: "Interview notes",
                    detail: "Screen and system design both flagged strong execution."
                ),
                DemoSource(
                    tool: .slack,
                    reference: "#hiring-backend",
                    detail: "Maya: worth pushing harder on scope in the next round.",
                    status: "2 days ago"
                )
            ],
            actions: ["View context", "Add to notes"]
        )))),

        .init(at: 16.2, action: .stage(.transcript("Technically she's clearly strong enough for the level."))),
        .init(at: 19.2, action: .stage(.transcript("I'm just not sure how much she's owned end to end."))),
        .init(at: 21.4, action: .stage(.listening("Following along"))),

        .init(at: 22.3, action: .stage(.insight(DemoInsight(
            title: "Gap in the loop",
            explanation: "Every round so far tested execution. Architecture-level ownership hasn't actually been probed by anyone.",
            evidence: [
                DemoEvidence(tool: .notion, label: "3 rounds, all execution-focused"),
                DemoEvidence(tool: .notion, label: "Scorecard: ownership unrated"),
                DemoEvidence(tool: .slack, label: "Raised once, never scheduled")
            ],
            quote: "I led the rollout, though the design was mostly set before I joined.",
            action: "Add question to interview plan"
        )))),

        .init(at: 30.0, action: .stage(.transcript("Let's add an ownership question to the final round."))),
        .init(at: 33.0, action: .stage(.transcript("Tell the next interviewer and get the debrief on the calendar."))),
        .init(at: 34.5, action: .stage(.acknowledgement("Got it — setting everything up"))),

        .init(at: 35.5, action: .stage(.workflow(DemoWorkflow(
            title: "Setting things up",
            steps: [
                DemoWorkflowStep(
                    tool: .notion,
                    progress: ["Updating scorecard"],
                    completed: "Scorecard updated",
                    details: [
                        "Architecture ownership added",
                        "Marked unvalidated",
                        "Question added to the plan"
                    ],
                    progressIndex: 0
                ),
                DemoWorkflowStep(
                    tool: .slack,
                    progress: ["Notifying next interviewer"],
                    completed: "Interviewer notified",
                    details: [
                        "Direct message sent",
                        "Prior notes attached",
                        "Focus area flagged"
                    ],
                    progressIndex: 0
                ),
                DemoWorkflowStep(
                    tool: .calendar,
                    progress: ["Finding time for the debrief", "Checking availability"],
                    completed: "Debrief scheduled",
                    details: [
                        "Backend hire debrief",
                        "Thursday, 16:00–16:30",
                        "4 attendees · video call added"
                    ],
                    progressIndex: 0
                )
            ]
        )))),
        .init(at: 38.0, action: .advance(.calendar)),
        .init(at: 39.2, action: .complete(.notion)),
        .init(at: 41.4, action: .complete(.slack)),
        .init(at: 43.8, action: .complete(.calendar)),

        .init(at: 45.6, action: .stage(.workflowResult(DemoWorkflowResult(
            title: "Everything is ready",
            outcomes: [
                DemoOutcome(tool: .notion, headline: "Scorecard updated", detail: "Architecture ownership added"),
                DemoOutcome(tool: .slack, headline: "Interviewer notified", detail: "Prior notes attached"),
                DemoOutcome(tool: .calendar, headline: "Debrief scheduled", detail: "Thursday at 16:00")
            ],
            confirmations: [
                "Interview plan updated",
                "Prior rounds attached",
                "Focus area flagged",
                "Invitations sent",
                "Video call link added"
            ],
            actions: ["View details", "Undo"]
        )))),

        .init(at: 50.2, action: .stage(.transcript("Make sure everyone has read the earlier rounds first."))),
        .init(at: 51.6, action: .stage(.brief(DemoBrief(
            title: "Debrief brief prepared",
            explanation: "I attached every prior round and the open question to the debrief, so nobody re-treads what's already answered.",
            attachments: [
                DemoEvidence(tool: .notion, label: "3 interview write-ups"),
                DemoEvidence(tool: .notion, label: "Candidate scorecard"),
                DemoEvidence(tool: .slack, label: "#hiring-backend thread"),
                DemoEvidence(tool: .calendar, label: "Final round, Wednesday")
            ],
            action: "View debrief brief"
        )))),

        .init(at: 55.8, action: .stage(.transcript("Good — that's everything. Let's wrap up."))),
        .init(at: 57.2, action: .stage(.ended)),

        .init(at: 58.4, action: .stage(.summary(DemoSummary(
            title: "Meeting summary ready",
            overview: "The panel rated execution strongly but found architecture-level ownership untested, and added it to the final round.",
            keyInsight: "All three completed rounds probed execution; ownership was raised once in Slack and never scheduled.",
            decisions: [
                "Add an ownership question to the final round",
                "Keep the level recommendation open until then",
                "Debrief as a full panel Thursday at 16:00"
            ],
            actionItems: [
                "Ask the architecture ownership question",
                "Update the scorecard after the round",
                "Read prior write-ups before the debrief",
                "Decide the level at the debrief"
            ],
            completed: [
                "Scorecard updated",
                "Ownership marked unvalidated",
                "Question added to the interview plan",
                "Next interviewer notified",
                "Prior notes attached",
                "Debrief scheduled",
                "Invitations sent",
                "Video call link added",
                "Debrief brief attached to the event"
            ],
            event: DemoEvent(
                title: "Backend hire debrief",
                when: "Thursday, 16:00–16:30",
                attendees: ["Maya Ostrowski", "Jonas Hedlund", "Priya Nair"],
                attachments: [
                    "3 interview write-ups",
                    "Candidate scorecard",
                    "Slack #hiring-backend",
                    "Final round notes"
                ],
                status: "Invitations sent"
            )
        ))))
    ]
}
