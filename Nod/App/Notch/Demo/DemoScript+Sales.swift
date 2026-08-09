import Foundation

// MARK: - Sales

extension DemoScenario {
    static let salesBeats: [DemoBeat] = [
        .init(at: 3.2, action: .stage(.transcript("The team likes it — we just can't sign this quarter."))),
        .init(at: 6.2, action: .stage(.transcript("There's a process we have to go through first."))),

        .init(at: 8.8, action: .stage(.searching("Checking account history"))),
        .init(at: 10.0, action: .stage(.context(DemoContext(
            lead: "Their procurement team already asked about this three weeks ago.",
            sources: [
                DemoSource(
                    tool: .crm,
                    reference: "Northwind — Expansion",
                    detail: "Stage: Proposal · close date slipped twice",
                    status: "At risk"
                ),
                DemoSource(
                    tool: .slack,
                    reference: "#deal-northwind",
                    detail: "Ines Duarte asked for a security questionnaire on the 12th."
                )
            ],
            actions: ["View context", "Add to notes"]
        )))),

        .init(at: 16.2, action: .stage(.transcript("We keep hearing it's a budget timing question."))),
        .init(at: 19.2, action: .stage(.transcript("But the date has moved twice now for different reasons."))),
        .init(at: 21.4, action: .stage(.listening("Following along"))),

        .init(at: 22.3, action: .stage(.insight(DemoInsight(
            title: "Likely blocker isn't budget",
            explanation: "Both slips followed a security question, not a budget cycle. The security review looks like the real gate.",
            evidence: [
                DemoEvidence(tool: .crm, label: "2 slips, both after security asks"),
                DemoEvidence(tool: .slack, label: "Questionnaire never returned"),
                DemoEvidence(tool: .notion, label: "Same pattern in 2 closed-lost deals")
            ],
            quote: "We can't move until infosec signs off — that's just how it works here.",
            action: "Add insight to notes"
        )))),

        .init(at: 30.0, action: .stage(.transcript("Let's get their security review moving this week."))),
        .init(at: 33.0, action: .stage(.transcript("Send the questionnaire and book time with their technical lead."))),
        .init(at: 34.5, action: .stage(.acknowledgement("Got it — setting everything up"))),

        .init(at: 35.5, action: .stage(.workflow(DemoWorkflow(
            title: "Setting things up",
            steps: [
                DemoWorkflowStep(
                    tool: .crm,
                    progress: ["Creating follow-up task"],
                    completed: "Task created",
                    details: [
                        "Drive security review to sign-off",
                        "Risk updated to Security",
                        "Close date flagged for review"
                    ],
                    progressIndex: 0
                ),
                DemoWorkflowStep(
                    tool: .slack,
                    progress: ["Drafting the follow-up"],
                    completed: "Draft ready",
                    details: [
                        "Follow-up message drafted",
                        "Questionnaire attached",
                        "Waiting for your send"
                    ],
                    progressIndex: 0
                ),
                DemoWorkflowStep(
                    tool: .calendar,
                    progress: ["Finding time for the review", "Checking availability"],
                    completed: "Review scheduled",
                    details: [
                        "Northwind security review",
                        "Tuesday, 15:00–15:45",
                        "5 attendees · video call added"
                    ],
                    progressIndex: 0
                )
            ]
        )))),
        .init(at: 38.0, action: .advance(.calendar)),
        .init(at: 39.2, action: .complete(.crm)),
        .init(at: 41.4, action: .complete(.slack)),
        .init(at: 43.8, action: .complete(.calendar)),

        .init(at: 45.6, action: .stage(.workflowResult(DemoWorkflowResult(
            title: "Everything is ready",
            outcomes: [
                DemoOutcome(tool: .crm, headline: "Task created", detail: "Drive security review to sign-off"),
                DemoOutcome(tool: .slack, headline: "Draft ready", detail: "Follow-up with questionnaire"),
                DemoOutcome(tool: .calendar, headline: "Review scheduled", detail: "Tuesday at 15:00")
            ],
            confirmations: [
                "Opportunity risk updated",
                "Technical lead invited",
                "Questionnaire attached",
                "Invitations sent",
                "Video call link added"
            ],
            actions: ["View details", "Undo"]
        )))),

        .init(at: 50.2, action: .stage(.transcript("They'll want the compliance documentation up front."))),
        .init(at: 51.6, action: .stage(.brief(DemoBrief(
            title: "Review pack prepared",
            explanation: "I attached the questionnaire and our security documentation to the invite, so their team can start before the call.",
            attachments: [
                DemoEvidence(tool: .notion, label: "Security questionnaire"),
                DemoEvidence(tool: .notion, label: "SOC 2 documentation"),
                DemoEvidence(tool: .crm, label: "Northwind — Expansion"),
                DemoEvidence(tool: .slack, label: "#deal-northwind")
            ],
            action: "View review pack"
        )))),

        .init(at: 55.8, action: .stage(.transcript("Good — that unblocks it. Let's wrap up."))),
        .init(at: 57.2, action: .stage(.ended)),

        .init(at: 58.4, action: .stage(.summary(DemoSummary(
            greeting: "Hey Jordan — here's where Northwind landed.",
            title: "Meeting summary ready",
            overview: "The team concluded that security review, not budget timing, is holding the Northwind expansion, and moved to unblock it this week.",
            keyInsight: "Both close-date slips followed a security question, and the questionnaire sent three weeks ago was never returned.",
            decisions: [
                "Treat security review as the deal blocker",
                "Send the questionnaire this week",
                "Book time with their technical lead",
                "Revisit the close date after sign-off"
            ],
            actionItems: [
                "Send the security questionnaire",
                "Drive the review to sign-off",
                "Confirm their infosec timeline",
                "Update the close date after the review"
            ],
            completed: [
                "CRM follow-up task created",
                "Opportunity risk updated to Security",
                "Follow-up message drafted",
                "Questionnaire attached",
                "Security review scheduled",
                "Technical lead invited",
                "Invitations sent",
                "Video call link added",
                "Documentation attached to the event"
            ],
            event: DemoEvent(
                title: "Northwind security review",
                when: "Tuesday, 15:00–15:45",
                attendees: ["Rachel Adeyemi", "Tom Weller", "Ines Duarte", "Mark Sullivan"],
                attachments: [
                    "Security questionnaire",
                    "SOC 2 documentation",
                    "CRM opportunity",
                    "Slack #deal-northwind"
                ],
                status: "Invitations sent"
            )
        ))))
    ]
}
