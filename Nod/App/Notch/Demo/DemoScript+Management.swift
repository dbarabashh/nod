import Foundation

// MARK: - Management

extension DemoScenario {
    static let managementBeats: [DemoBeat] = [
        .init(at: 3.2, action: .stage(.transcript("Are we still good for the release at the end of the month?"))),
        .init(at: 6.2, action: .stage(.transcript("Everyone says yes, but nothing has moved in two weeks."))),

        .init(at: 8.8, action: .stage(.searching("Checking project status"))),
        .init(at: 10.0, action: .stage(.context(DemoContext(
            lead: "Two epics are past their dates, and a release blocker is still open.",
            sources: [
                DemoSource(
                    tool: .jira,
                    reference: "PLAT-92, PLAT-97",
                    detail: "Both past due — no estimate update since the 9th",
                    status: "Overdue"
                ),
                DemoSource(
                    tool: .github,
                    reference: "release/4.2",
                    detail: "One blocking pull request open for 11 days."
                )
            ],
            actions: ["View context", "Add to notes"]
        )))),

        .init(at: 16.2, action: .stage(.transcript("Each team on its own says they're on track."))),
        .init(at: 19.2, action: .stage(.transcript("So where is the month actually going?"))),
        .init(at: 21.4, action: .stage(.listening("Following along"))),

        .init(at: 22.3, action: .stage(.insight(DemoInsight(
            title: "Launch date is at risk",
            explanation: "The two overdue epics both feed the blocked pull request. Sequentially there isn't a path to the end of the month.",
            evidence: [
                DemoEvidence(tool: .jira, label: "2 epics overdue by 9 days"),
                DemoEvidence(tool: .github, label: "Blocking PR open 11 days"),
                DemoEvidence(tool: .slack, label: "No status update since the 9th")
            ],
            quote: "We're blocked on the platform change, but I assumed someone else was chasing it.",
            action: "Add insight to notes"
        )))),

        .init(at: 30.0, action: .stage(.transcript("Let's put a mitigation plan together and re-estimate."))),
        .init(at: 33.0, action: .stage(.transcript("Ping the owners and get a launch-risk review on the calendar."))),
        .init(at: 34.5, action: .stage(.acknowledgement("Got it — setting everything up"))),

        .init(at: 35.5, action: .stage(.workflow(DemoWorkflow(
            title: "Setting things up",
            steps: [
                DemoWorkflowStep(
                    tool: .notion,
                    progress: ["Drafting mitigation plan"],
                    completed: "Plan created",
                    details: [
                        "Release 4.2 mitigation plan",
                        "Both epics and the blocker listed",
                        "Owners assigned"
                    ],
                    progressIndex: 0
                ),
                DemoWorkflowStep(
                    tool: .jira,
                    progress: ["Creating follow-up tasks"],
                    completed: "Tasks created",
                    details: [
                        "Re-estimate PLAT-92 and PLAT-97",
                        "Unblock the release pull request",
                        "Linked to the mitigation plan"
                    ],
                    progressIndex: 0
                ),
                DemoWorkflowStep(
                    tool: .calendar,
                    progress: ["Finding time for the review", "Checking availability"],
                    completed: "Review scheduled",
                    details: [
                        "Release 4.2 launch-risk review",
                        "Monday, 09:30–10:00",
                        "6 attendees · video call added"
                    ],
                    progressIndex: 0
                )
            ]
        )))),
        .init(at: 38.0, action: .advance(.calendar)),
        .init(at: 39.2, action: .complete(.notion)),
        .init(at: 41.4, action: .complete(.jira)),
        .init(at: 43.8, action: .complete(.calendar)),

        .init(at: 45.6, action: .stage(.workflowResult(DemoWorkflowResult(
            title: "Everything is ready",
            outcomes: [
                DemoOutcome(tool: .notion, headline: "Plan created", detail: "Release 4.2 mitigation plan"),
                DemoOutcome(tool: .jira, headline: "Tasks created", detail: "Re-estimate and unblock"),
                DemoOutcome(tool: .calendar, headline: "Review scheduled", detail: "Monday at 09:30")
            ],
            confirmations: [
                "Owners notified in Slack",
                "Updated estimates requested",
                "Blocking pull request flagged",
                "Invitations sent",
                "Video call link added"
            ],
            actions: ["View details", "Undo"]
        )))),

        .init(at: 50.2, action: .stage(.transcript("Everyone should see the evidence before Monday."))),
        .init(at: 51.6, action: .stage(.brief(DemoBrief(
            title: "Risk brief prepared",
            explanation: "I attached the plan and the project evidence to the invite, so the review starts from the same picture.",
            attachments: [
                DemoEvidence(tool: .notion, label: "Mitigation plan"),
                DemoEvidence(tool: .jira, label: "PLAT-92, PLAT-97"),
                DemoEvidence(tool: .github, label: "release/4.2 blocker"),
                DemoEvidence(tool: .slack, label: "#release-4-2")
            ],
            action: "View risk brief"
        )))),

        .init(at: 55.8, action: .stage(.transcript("Good — now we're looking at the same thing. Let's wrap up."))),
        .init(at: 57.2, action: .stage(.ended)),

        .init(at: 58.4, action: .stage(.summary(DemoSummary(
            title: "Meeting summary ready",
            overview: "The group found the end-of-month release at risk from two overdue epics feeding a blocked pull request, and agreed on a mitigation plan.",
            keyInsight: "Both overdue epics feed the same blocking pull request, which has been open eleven days with no status update since the 9th.",
            decisions: [
                "Treat the release date as at risk",
                "Re-estimate PLAT-92 and PLAT-97",
                "Unblock the release pull request first",
                "Review launch risk Monday at 09:30"
            ],
            actionItems: [
                "Re-estimate both overdue epics",
                "Unblock the release pull request",
                "Confirm the revised launch date",
                "Report status before Monday"
            ],
            completed: [
                "Mitigation plan created",
                "Jira follow-up tasks created",
                "Epics linked to the plan",
                "Owners notified in Slack",
                "Updated estimates requested",
                "Launch-risk review scheduled",
                "Invitations sent",
                "Video call link added",
                "Risk brief attached to the event"
            ],
            event: DemoEvent(
                title: "Release 4.2 launch-risk review",
                when: "Monday, 09:30–10:00",
                attendees: ["Elena Vasquez", "Tobias Krause", "Ayesha Rahman", "Nils Berger", "Clara Jensen"],
                attachments: [
                    "Mitigation plan",
                    "Jira PLAT-92, PLAT-97",
                    "GitHub release/4.2",
                    "Slack #release-4-2"
                ],
                status: "Invitations sent"
            )
        ))))
    ]
}
