import SwiftUI

// MARK: - Sales

/// Same fictional world as `DemoScenario.salesBeats`: Jordan is the viewer,
/// Rachel Adeyemi / Tom Weller / Ines Duarte / Mark Sullivan are the Northwind
/// contacts, #deal-northwind is the thread, Tuesday 15:00 is the security
/// review the whole scenario has been building toward.
let salesDailyModes: [DemoDailyMode: DemoDailyModeContent] = [
    .morningBriefing: DemoDailyModeContent(
        greeting: "Good morning, Jordan.",
        summary: "Northwind's security review is the thing to watch this week.",
        rows: [
            DemoDailyRow(
                glyph: .person(name: "Rachel Adeyemi", tint: Theme.Palette.brand),
                title: "Rachel Adeyemi opened the questionnaire",
                subtitle: "Northwind's infosec team started the review",
                meta: "6:48 AM"
            ),
            DemoDailyRow(
                glyph: .tool(.crm),
                title: "Northwind risk updated to Security",
                subtitle: "Auto-flagged after Monday's call",
                meta: "Yesterday"
            ),
            DemoDailyRow(
                glyph: .tool(.calendar),
                title: "Northwind security review",
                subtitle: "Tuesday, 15:00 · 4 attendees",
                meta: "in 2 days"
            )
        ],
        footerAction: "Open the Northwind opportunity"
    ),
    .catchUp: DemoDailyModeContent(
        greeting: nil,
        summary: "2 updates on Northwind since yesterday.",
        rows: [
            DemoDailyRow(
                glyph: .tool(.slack),
                title: "3 new messages in #deal-northwind",
                subtitle: "Tom: \"Their technical lead is looped in\"",
                meta: "Yesterday"
            ),
            DemoDailyRow(
                glyph: .tool(.crm),
                title: "Opportunity stage unchanged",
                subtitle: "Still waiting on the security sign-off",
                meta: "Yesterday"
            ),
            DemoDailyRow(
                glyph: .person(name: "Ines Duarte", tint: Theme.Palette.cyan),
                title: "Ines Duarte confirmed Tuesday",
                subtitle: "Their technical lead can join the review",
                meta: "This morning"
            )
        ],
        footerAction: "Reply in #deal-northwind"
    ),
    .actionPlan: DemoDailyModeContent(
        greeting: nil,
        summary: "3 things on you today.",
        rows: [
            DemoDailyRow(
                glyph: .system(icon: "nc-flag-7", tint: Theme.Palette.danger),
                title: "Send the security questionnaire",
                subtitle: "Blocks the review Tuesday",
                meta: "Due today"
            ),
            DemoDailyRow(
                glyph: .system(icon: "nc-tasks-2"),
                title: "Confirm Northwind's infosec timeline",
                subtitle: "Ask on the review call",
                meta: "Due Tuesday"
            ),
            DemoDailyRow(
                glyph: .system(icon: "nc-money-bill-coin"),
                title: "Update the close date",
                subtitle: "After the review wraps",
                meta: "Due Wednesday"
            )
        ],
        footerAction: "Start with the questionnaire"
    ),
    .deepWork: DemoDailyModeContent(
        greeting: nil,
        summary: "One block open before the Northwind call.",
        rows: [
            DemoDailyRow(
                glyph: .system(icon: "nc-target", tint: Theme.Palette.brand),
                title: "Prep the Northwind security packet",
                subtitle: "60 min, no meetings until 2 PM",
                meta: "1:00 – 2:00 PM"
            ),
            DemoDailyRow(
                glyph: .tool(.crm),
                title: "Related: SOC 2 docs, questionnaire draft",
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
        summary: "5 unread, 1 needs you before Tuesday.",
        rows: [
            DemoDailyRow(
                glyph: .tool(.gmail),
                title: "Rachel Adeyemi — Security questionnaire, signed",
                subtitle: "\"Sent our side back, over to you\"",
                meta: "8:10 AM"
            ),
            DemoDailyRow(
                glyph: .tool(.gmail),
                title: "Mark Sullivan — Re: Tuesday's review",
                subtitle: "\"Confirmed, see you then\"",
                meta: "7:50 AM"
            ),
            DemoDailyRow(
                glyph: .tool(.gmail),
                title: "HubSpot — Weekly pipeline digest",
                subtitle: "Northwind flagged as at-risk",
                meta: "6:00 AM"
            )
        ],
        footerAction: "Open inbox"
    ),
    .meetingPrep: DemoDailyModeContent(
        greeting: nil,
        summary: "Next up: Northwind security review, Tuesday 15:00.",
        rows: [
            DemoDailyRow(
                glyph: .tool(.calendar),
                title: "Northwind security review",
                subtitle: "Tuesday, 15:00 – 15:45 · 4 attendees",
                meta: "in 2 days"
            ),
            DemoDailyRow(
                glyph: .tool(.crm),
                title: "Northwind — Security risk",
                subtitle: "Two close-date slips followed a security question",
                meta: "Linked"
            ),
            DemoDailyRow(
                glyph: .system(icon: "nc-users"),
                title: "Rachel Adeyemi, Tom Weller, Ines Duarte, Mark Sullivan",
                subtitle: "All confirmed",
                meta: "4 attendees"
            )
        ],
        footerAction: "View review brief"
    ),
    .dailyRecap: DemoDailyModeContent(
        greeting: "Hey Jordan — here's today.",
        summary: "Northwind's questionnaire is back; review is on for Tuesday.",
        rows: [
            DemoDailyRow(
                glyph: .tool(.crm),
                title: "Northwind risk stays Security",
                subtitle: "Questionnaire returned, review confirmed",
                meta: "Today"
            ),
            DemoDailyRow(
                glyph: .tool(.slack),
                title: "#deal-northwind stayed active",
                subtitle: "5 messages, technical lead looped in",
                meta: "Today"
            ),
            DemoDailyRow(
                glyph: .system(icon: "nc-check", tint: Theme.Palette.success),
                title: "1 of 3 action items closed",
                subtitle: "Questionnaire sent — review is next",
                meta: "Today"
            )
        ],
        footerAction: "Review tomorrow's plan"
    )
]
