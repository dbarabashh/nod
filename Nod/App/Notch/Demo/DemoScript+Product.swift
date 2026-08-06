import Foundation

// MARK: - Product & Engineering

extension DemoScenario {
    static let productEngineeringBeats: [DemoBeat] = [
        .init(at: 3.2, action: .stage(.transcript("We're still seeing users drop off during onboarding."))),
        .init(at: 6.2, action: .stage(.transcript("Has anyone already looked into the permissions step?"))),

        .init(at: 8.8, action: .stage(.searching("Looking for relevant context…"))),
        .init(at: 10.0, action: .stage(.context(DemoContext(
            lead: "Peter raised this in Slack — and there's already a ticket open for it.",
            sources: [
                DemoSource(
                    tool: .slack,
                    reference: "#product",
                    detail: "Peter: users were confused by the onboarding permissions step."
                ),
                DemoSource(
                    tool: .jira,
                    reference: "ONB-184",
                    detail: "Improve onboarding permissions step",
                    status: "In Progress"
                )
            ],
            actions: ["View context", "Add to notes"]
        )))),

        .init(at: 16.2, action: .stage(.transcript("We assumed the problem was that onboarding has too many steps."))),
        .init(at: 19.2, action: .stage(.transcript("But we still don't know which step actually loses people."))),
        .init(at: 21.4, action: .stage(.listening("Following along…"))),

        .init(at: 22.3, action: .stage(.insight(DemoInsight(
            title: "Possible root cause found",
            explanation: "It may not be the number of steps. People appear to stall on the workspace permissions screen.",
            evidence: [
                DemoEvidence(tool: .support, label: "14 support conversations"),
                DemoEvidence(tool: .calendar, label: "3 recent customer calls"),
                DemoEvidence(tool: .notion, label: "Onboarding research doc")
            ],
            quote: "I wasn't sure what access my teammates would get.",
            action: "Add insight to notes"
        )))),

        .init(at: 30.0, action: .stage(.transcript("Let's redesign the permissions step and review it Friday."))),
        .init(at: 33.0, action: .stage(.transcript("Spin up a Slack channel and pull in product, design, engineering and support."))),
        .init(at: 34.5, action: .stage(.acknowledgement("Got it — setting everything up…"))),

        .init(at: 35.5, action: .stage(.workflow(DemoWorkflow(
            title: "Setting things up",
            steps: [
                DemoWorkflowStep(
                    tool: .notion,
                    progress: ["Creating redesign task…"],
                    completed: "Task created",
                    details: [
                        "Redesign onboarding permissions step",
                        "Due Friday",
                        "Linked to Jira ONB-184"
                    ],
                    progressIndex: 0
                ),
                DemoWorkflowStep(
                    tool: .slack,
                    progress: ["Setting up working group…"],
                    completed: "Channel created",
                    details: [
                        "#onboarding-fix",
                        "Relevant people invited",
                        "Context posted and pinned"
                    ],
                    progressIndex: 0
                ),
                DemoWorkflowStep(
                    tool: .calendar,
                    progress: ["Finding time for the review…", "Checking availability…"],
                    completed: "Follow-up scheduled",
                    details: [
                        "Onboarding permissions review",
                        "Friday, 10:30–11:00",
                        "5 attendees · video call added"
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
                DemoOutcome(tool: .notion, headline: "Task created", detail: "Redesign onboarding permissions step"),
                DemoOutcome(tool: .slack, headline: "Channel created", detail: "#onboarding-fix"),
                DemoOutcome(tool: .calendar, headline: "Review scheduled", detail: "Friday at 10:30")
            ],
            confirmations: [
                "Jira ONB-184 linked",
                "Relevant people invited",
                "Context posted and pinned",
                "Invitations sent",
                "Video call link added"
            ],
            actions: ["View details", "Undo"]
        )))),

        .init(at: 50.2, action: .stage(.transcript("Let's have the customer evidence ready before the review."))),
        .init(at: 51.6, action: .stage(.brief(DemoBrief(
            title: "Review brief prepared",
            explanation: "I attached the strongest evidence to the calendar event, so everyone has the context before Friday.",
            attachments: [
                DemoEvidence(tool: .support, label: "14 support conversations"),
                DemoEvidence(tool: .calendar, label: "3 customer call excerpts"),
                DemoEvidence(tool: .notion, label: "Onboarding research doc"),
                DemoEvidence(tool: .jira, label: "ONB-184"),
                DemoEvidence(tool: .slack, label: "#onboarding-fix")
            ],
            action: "View review brief"
        )))),

        .init(at: 55.8, action: .stage(.transcript("Good — I think we have everything. Let's wrap up."))),
        .init(at: 57.2, action: .stage(.ended)),

        .init(at: 58.4, action: .stage(.summary(DemoSummary(
            title: "Meeting summary ready",
            overview: "The team pinned onboarding drop-off on confusion about workspace permissions, and agreed to redesign that step.",
            keyInsight: "Fourteen support conversations and three customer calls mention confusion about workspace permissions.",
            decisions: [
                "Redesign the permissions step",
                "Continue implementation in Jira ONB-184",
                "Coordinate in #onboarding-fix",
                "Review the updated design Friday at 10:30"
            ],
            actionItems: [
                "Redesign the onboarding permissions step",
                "Validate the implementation approach",
                "Prepare customer evidence for the review",
                "Review the updated design on Friday"
            ],
            completed: [
                "Notion task created",
                "Jira ONB-184 linked",
                "Slack channel #onboarding-fix created",
                "Relevant people invited",
                "Context posted and pinned",
                "Calendar event created",
                "Invitations sent",
                "Video call link added",
                "Review brief attached to the event"
            ],
            event: DemoEvent(
                title: "Onboarding permissions review",
                when: "Friday, 10:30–11:00",
                attendees: ["Peter Lang", "Sofia Marchetti", "Daniel Okoye", "Hanna Bauer"],
                attachments: [
                    "Jira ONB-184",
                    "Notion redesign task",
                    "Notion onboarding research",
                    "Slack #onboarding-fix",
                    "Customer evidence summary"
                ],
                status: "Invitations sent"
            )
        ))))
    ]
}
