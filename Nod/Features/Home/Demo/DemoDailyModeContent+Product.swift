import SwiftUI

// MARK: - Product & Engineering

/// Same fictional world as `DemoScenario.productEngineeringBeats`: Maya is the
/// viewer, Peter Lang / Sofia Marchetti / Daniel Okoye / Hanna Bauer are the
/// team, ONB-184 and #onboarding-fix are the thread, Friday 10:30 is the
/// review the whole scenario has been building toward.
let productEngineeringDailyModes: [DemoDailyMode: DemoDailyModeContent] = [
    .morningBriefing: DemoDailyModeContent(
        greeting: "Good morning, Maya.",
        summary: "Onboarding's still the story — here's what moved overnight.",
        rows: [
            DemoDailyRow(
                glyph: .person(name: "Sofia Marchetti", tint: Theme.Palette.brand),
                title: "Sofia Marchetti finished the redesign mock",
                subtitle: "Attached to ONB-184, ready for review",
                meta: "7:12 AM"
            ),
            DemoDailyRow(
                glyph: .tool(.slack),
                title: "4 new messages in #onboarding-fix",
                subtitle: "Daniel: \"Copy's ready whenever\"",
                meta: "7:40 AM"
            ),
            DemoDailyRow(
                glyph: .tool(.calendar),
                title: "Onboarding permissions review",
                subtitle: "Friday, 10:30 · 4 attendees",
                meta: "in 2 days"
            )
        ],
        footerAction: "Open #onboarding-fix"
    ),
    .catchUp: DemoDailyModeContent(
        greeting: nil,
        summary: "3 updates since you last looked.",
        rows: [
            DemoDailyRow(
                glyph: .tool(.jira),
                title: "ONB-184 moved to In Review",
                subtitle: "Sofia Marchetti",
                meta: "Yesterday, 4:20 PM"
            ),
            DemoDailyRow(
                glyph: .tool(.support),
                title: "2 new support conversations",
                subtitle: "Both mention the permissions screen",
                meta: "Yesterday"
            ),
            DemoDailyRow(
                glyph: .person(name: "Daniel Okoye", tint: Theme.Palette.cyan),
                title: "Daniel Okoye asked a question",
                subtitle: "\"Should the redesign gate invites too?\" in #onboarding-fix",
                meta: "This morning"
            )
        ],
        footerAction: "Reply in #onboarding-fix"
    ),
    .actionPlan: DemoDailyModeContent(
        greeting: nil,
        summary: "3 things on you today.",
        rows: [
            DemoDailyRow(
                glyph: .system(icon: "nc-flag-7", tint: Theme.Palette.danger),
                title: "Review the permissions redesign",
                subtitle: "Blocks Friday's review",
                meta: "Due today"
            ),
            DemoDailyRow(
                glyph: .system(icon: "nc-tasks-2"),
                title: "Validate the implementation approach",
                subtitle: "From Tuesday's meeting",
                meta: "Due tomorrow"
            ),
            DemoDailyRow(
                glyph: .system(icon: "nc-msgs"),
                title: "Answer Daniel's question in #onboarding-fix",
                subtitle: "Open since this morning",
                meta: "Unread"
            )
        ],
        footerAction: "Start with the redesign review"
    ),
    .deepWork: DemoDailyModeContent(
        greeting: nil,
        summary: "One clear block open before the review.",
        rows: [
            DemoDailyRow(
                glyph: .system(icon: "nc-target", tint: Theme.Palette.brand),
                title: "Permissions redesign review",
                subtitle: "90 min, no meetings until 1 PM",
                meta: "9:00 – 10:30 AM"
            ),
            DemoDailyRow(
                glyph: .tool(.notion),
                title: "Related: ONB-184, onboarding research doc",
                subtitle: "Pulled in automatically",
                meta: "2 docs"
            ),
            DemoDailyRow(
                glyph: .system(icon: "nc-bell-slash"),
                title: "Notifications muted for this block",
                subtitle: "Slack and email paused",
                meta: "Auto"
            )
        ],
        footerAction: "Start focus session"
    ),
    .inbox: DemoDailyModeContent(
        greeting: nil,
        summary: "6 unread, 1 needs you before Friday.",
        rows: [
            DemoDailyRow(
                glyph: .tool(.gmail),
                title: "Hanna Bauer — Re: onboarding review invite",
                subtitle: "\"Works for me, see you Friday\"",
                meta: "8:02 AM"
            ),
            DemoDailyRow(
                glyph: .tool(.gmail),
                title: "Peter Lang — Customer quote for the review",
                subtitle: "Attached: 1 support transcript",
                meta: "7:55 AM"
            ),
            DemoDailyRow(
                glyph: .tool(.gmail),
                title: "Notion — Weekly digest",
                subtitle: "3 pages updated in your workspace",
                meta: "6:00 AM"
            )
        ],
        footerAction: "Open inbox"
    ),
    .meetingPrep: DemoDailyModeContent(
        greeting: nil,
        summary: "Next up: Onboarding permissions review, Friday 10:30.",
        rows: [
            DemoDailyRow(
                glyph: .tool(.calendar),
                title: "Onboarding permissions review",
                subtitle: "Friday, 10:30 – 11:00 · 4 attendees",
                meta: "in 2 days"
            ),
            DemoDailyRow(
                glyph: .tool(.jira),
                title: "ONB-184 — In Review",
                subtitle: "Redesign mock attached by Sofia",
                meta: "Linked"
            ),
            DemoDailyRow(
                glyph: .system(icon: "nc-users"),
                title: "Peter Lang, Sofia Marchetti, Daniel Okoye, Hanna Bauer",
                subtitle: "All confirmed",
                meta: "4 attendees"
            )
        ],
        footerAction: "View review brief"
    ),
    .dailyRecap: DemoDailyModeContent(
        greeting: "Hey Maya — here's today.",
        summary: "Onboarding moved to review; nothing else slipped.",
        rows: [
            DemoDailyRow(
                glyph: .tool(.jira),
                title: "ONB-184 moved to In Review",
                subtitle: "Redesign mock ready for Friday",
                meta: "Today"
            ),
            DemoDailyRow(
                glyph: .tool(.slack),
                title: "#onboarding-fix stayed active",
                subtitle: "6 messages, 1 open question",
                meta: "Today"
            ),
            DemoDailyRow(
                glyph: .system(icon: "nc-check", tint: Theme.Palette.success),
                title: "2 of 3 action items closed",
                subtitle: "Redesign review is the one left",
                meta: "Today"
            )
        ],
        footerAction: "Review tomorrow's plan"
    )
]
