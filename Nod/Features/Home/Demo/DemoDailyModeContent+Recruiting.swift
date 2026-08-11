import SwiftUI

// MARK: - Recruiting

/// Same fictional world as `DemoScenario.recruitingBeats`: Priya is the
/// viewer, Maya Ostrowski / Jonas Hedlund / Priya Nair are the panel,
/// #hiring-backend is the thread, Thursday 16:00 is the debrief the whole
/// scenario has been building toward.
let recruitingDailyModes: [DemoDailyMode: DemoDailyModeContent] = [
    .morningBriefing: DemoDailyModeContent(
        greeting: "Good morning, Priya.",
        summary: "The backend hire debrief is Thursday — one question still open.",
        rows: [
            DemoDailyRow(
                glyph: .person(name: "Jonas Hedlund", tint: Theme.Palette.brand),
                title: "Jonas Hedlund updated the scorecard",
                subtitle: "Marked ownership as unvalidated",
                meta: "7:15 AM"
            ),
            DemoDailyRow(
                glyph: .tool(.slack),
                title: "2 new messages in #hiring-backend",
                subtitle: "Maya: \"Final round confirmed for Wednesday\"",
                meta: "7:50 AM"
            ),
            DemoDailyRow(
                glyph: .tool(.calendar),
                title: "Backend hire debrief",
                subtitle: "Thursday, 16:00 · 3 attendees",
                meta: "in 3 days"
            )
        ],
        footerAction: "Open #hiring-backend"
    ),
    .catchUp: DemoDailyModeContent(
        greeting: nil,
        summary: "2 updates on the backend hire since yesterday.",
        rows: [
            DemoDailyRow(
                glyph: .tool(.slack),
                title: "Ownership question raised",
                subtitle: "Once in #hiring-backend, not yet scheduled",
                meta: "Yesterday"
            ),
            DemoDailyRow(
                glyph: .person(name: "Maya Ostrowski", tint: Theme.Palette.cyan),
                title: "Maya Ostrowski scheduled the final round",
                subtitle: "Wednesday, architecture focus",
                meta: "Yesterday"
            ),
            DemoDailyRow(
                glyph: .tool(.notion),
                title: "3 prior write-ups updated",
                subtitle: "All rounds now scored",
                meta: "This morning"
            )
        ],
        footerAction: "Reply in #hiring-backend"
    ),
    .actionPlan: DemoDailyModeContent(
        greeting: nil,
        summary: "3 things on you today.",
        rows: [
            DemoDailyRow(
                glyph: .system(icon: "nc-flag-7", tint: Theme.Palette.danger),
                title: "Ask the architecture ownership question",
                subtitle: "In Wednesday's final round",
                meta: "Due Wednesday"
            ),
            DemoDailyRow(
                glyph: .system(icon: "nc-tasks-2"),
                title: "Update the scorecard after the round",
                subtitle: "Keep the level recommendation open",
                meta: "Due Wednesday"
            ),
            DemoDailyRow(
                glyph: .system(icon: "nc-graduation-cap"),
                title: "Read prior write-ups before the debrief",
                subtitle: "3 rounds to review",
                meta: "Due Thursday"
            )
        ],
        footerAction: "Start with prior write-ups"
    ),
    .deepWork: DemoDailyModeContent(
        greeting: nil,
        summary: "One block open before the debrief.",
        rows: [
            DemoDailyRow(
                glyph: .system(icon: "nc-target", tint: Theme.Palette.brand),
                title: "Read the 3 interview write-ups",
                subtitle: "45 min, no meetings until 3 PM",
                meta: "2:15 – 3:00 PM"
            ),
            DemoDailyRow(
                glyph: .tool(.notion),
                title: "Related: candidate scorecard, panel notes",
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
        summary: "4 unread, 1 needs you before Thursday.",
        rows: [
            DemoDailyRow(
                glyph: .tool(.gmail),
                title: "Jonas Hedlund — Scorecard, updated",
                subtitle: "\"Ownership still open, flagged it\"",
                meta: "8:05 AM"
            ),
            DemoDailyRow(
                glyph: .tool(.gmail),
                title: "Maya Ostrowski — Final round confirmed",
                subtitle: "Wednesday, architecture focus",
                meta: "7:45 AM"
            ),
            DemoDailyRow(
                glyph: .tool(.gmail),
                title: "Greenhouse — Candidate reminder",
                subtitle: "Debrief due Thursday",
                meta: "6:00 AM"
            )
        ],
        footerAction: "Open inbox"
    ),
    .meetingPrep: DemoDailyModeContent(
        greeting: nil,
        summary: "Next up: Backend hire debrief, Thursday 16:00.",
        rows: [
            DemoDailyRow(
                glyph: .tool(.calendar),
                title: "Backend hire debrief",
                subtitle: "Thursday, 16:00 – 16:30 · 3 attendees",
                meta: "in 3 days"
            ),
            DemoDailyRow(
                glyph: .tool(.notion),
                title: "Candidate scorecard",
                subtitle: "Execution strong, ownership untested",
                meta: "Linked"
            ),
            DemoDailyRow(
                glyph: .system(icon: "nc-users"),
                title: "Maya Ostrowski, Jonas Hedlund, Priya Nair",
                subtitle: "All confirmed",
                meta: "3 attendees"
            )
        ],
        footerAction: "View debrief brief"
    ),
    .dailyRecap: DemoDailyModeContent(
        greeting: "Hey Priya — here's today.",
        summary: "Final round is set; ownership is the one thing left to test.",
        rows: [
            DemoDailyRow(
                glyph: .tool(.notion),
                title: "Scorecard updated",
                subtitle: "Ownership marked unvalidated",
                meta: "Today"
            ),
            DemoDailyRow(
                glyph: .tool(.slack),
                title: "#hiring-backend stayed active",
                subtitle: "2 messages, final round confirmed",
                meta: "Today"
            ),
            DemoDailyRow(
                glyph: .system(icon: "nc-check", tint: Theme.Palette.success),
                title: "2 of 3 action items closed",
                subtitle: "Debrief prep is the one left",
                meta: "Today"
            )
        ],
        footerAction: "Review tomorrow's plan"
    )
]
