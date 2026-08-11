import SwiftUI

// MARK: - Management

/// Same fictional world as `DemoScenario.managementBeats`: Alex is the
/// viewer, Elena Vasquez / Tobias Krause / Ayesha Rahman / Nils Berger /
/// Clara Jensen are the team, PLAT-92/PLAT-97 and #release-4-2 are the
/// thread, Monday 09:30 is the launch-risk review the whole scenario has
/// been building toward.
let managementDailyModes: [DemoDailyMode: DemoDailyModeContent] = [
    .morningBriefing: DemoDailyModeContent(
        greeting: "Good morning, Alex.",
        summary: "Release 4.2 is still the risk to watch — two epics, one blocked PR.",
        rows: [
            DemoDailyRow(
                glyph: .person(name: "Tobias Krause", tint: Theme.Palette.brand),
                title: "Tobias Krause re-estimated PLAT-92",
                subtitle: "New estimate: 3 days, was 1",
                meta: "6:55 AM"
            ),
            DemoDailyRow(
                glyph: .tool(.github),
                title: "release/4.2 — no update in 11 days",
                subtitle: "Still blocking the release",
                meta: "Ongoing"
            ),
            DemoDailyRow(
                glyph: .tool(.calendar),
                title: "Release 4.2 launch-risk review",
                subtitle: "Monday, 09:30 · 5 attendees",
                meta: "in 3 days"
            )
        ],
        footerAction: "Open #release-4-2"
    ),
    .catchUp: DemoDailyModeContent(
        greeting: nil,
        summary: "3 updates on Release 4.2 since yesterday.",
        rows: [
            DemoDailyRow(
                glyph: .tool(.jira),
                title: "PLAT-92 re-estimated",
                subtitle: "Tobias Krause — 3 days, was 1",
                meta: "Yesterday"
            ),
            DemoDailyRow(
                glyph: .person(name: "Ayesha Rahman", tint: Theme.Palette.cyan),
                title: "Ayesha Rahman flagged PLAT-97",
                subtitle: "Also blocked on the same PR",
                meta: "Yesterday"
            ),
            DemoDailyRow(
                glyph: .tool(.slack),
                title: "4 new messages in #release-4-2",
                subtitle: "Nils: \"PR review is next on my list\"",
                meta: "This morning"
            )
        ],
        footerAction: "Reply in #release-4-2"
    ),
    .actionPlan: DemoDailyModeContent(
        greeting: nil,
        summary: "3 things on you today.",
        rows: [
            DemoDailyRow(
                glyph: .system(icon: "nc-flag-7", tint: Theme.Palette.danger),
                title: "Unblock the release pull request",
                subtitle: "Both overdue epics feed it",
                meta: "Due today"
            ),
            DemoDailyRow(
                glyph: .system(icon: "nc-tasks-2"),
                title: "Confirm the revised launch date",
                subtitle: "After both epics are re-estimated",
                meta: "Due tomorrow"
            ),
            DemoDailyRow(
                glyph: .system(icon: "nc-bullhorn"),
                title: "Report status before Monday",
                subtitle: "For the launch-risk review",
                meta: "Due Sunday"
            )
        ],
        footerAction: "Start with the pull request"
    ),
    .deepWork: DemoDailyModeContent(
        greeting: nil,
        summary: "One block open before the risk review.",
        rows: [
            DemoDailyRow(
                glyph: .system(icon: "nc-target", tint: Theme.Palette.brand),
                title: "Review the blocking pull request",
                subtitle: "45 min, no meetings until 11 AM",
                meta: "10:15 – 11:00 AM"
            ),
            DemoDailyRow(
                glyph: .tool(.jira),
                title: "Related: mitigation plan, PLAT-92/97",
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
        summary: "7 unread, 1 needs you before Monday.",
        rows: [
            DemoDailyRow(
                glyph: .tool(.gmail),
                title: "Elena Vasquez — Re: launch-risk review",
                subtitle: "\"Confirmed for Monday, bringing the numbers\"",
                meta: "8:15 AM"
            ),
            DemoDailyRow(
                glyph: .tool(.gmail),
                title: "Clara Jensen — Mitigation plan draft",
                subtitle: "Attached: PLAT-92/97 estimates",
                meta: "7:50 AM"
            ),
            DemoDailyRow(
                glyph: .tool(.gmail),
                title: "GitHub — release/4.2 review requested",
                subtitle: "11 days with no update",
                meta: "6:00 AM"
            )
        ],
        footerAction: "Open inbox"
    ),
    .meetingPrep: DemoDailyModeContent(
        greeting: nil,
        summary: "Next up: Release 4.2 launch-risk review, Monday 09:30.",
        rows: [
            DemoDailyRow(
                glyph: .tool(.calendar),
                title: "Release 4.2 launch-risk review",
                subtitle: "Monday, 09:30 – 10:00 · 5 attendees",
                meta: "in 3 days"
            ),
            DemoDailyRow(
                glyph: .tool(.github),
                title: "release/4.2",
                subtitle: "Blocked 11 days, no status update since the 9th",
                meta: "Linked"
            ),
            DemoDailyRow(
                glyph: .system(icon: "nc-users"),
                title: "Elena Vasquez, Tobias Krause, Ayesha Rahman, Nils Berger, Clara Jensen",
                subtitle: "All confirmed",
                meta: "5 attendees"
            )
        ],
        footerAction: "View risk brief"
    ),
    .dailyRecap: DemoDailyModeContent(
        greeting: "Hey Alex — here's today.",
        summary: "Both epics re-estimated; the blocked PR is now the whole story.",
        rows: [
            DemoDailyRow(
                glyph: .tool(.jira),
                title: "PLAT-92 and PLAT-97 re-estimated",
                subtitle: "Both feed the same blocked PR",
                meta: "Today"
            ),
            DemoDailyRow(
                glyph: .tool(.slack),
                title: "#release-4-2 stayed active",
                subtitle: "4 messages, review promised next",
                meta: "Today"
            ),
            DemoDailyRow(
                glyph: .system(icon: "nc-check", tint: Theme.Palette.success),
                title: "2 of 3 action items closed",
                subtitle: "Unblocking the PR is the one left",
                meta: "Today"
            )
        ],
        footerAction: "Review tomorrow's plan"
    )
]
