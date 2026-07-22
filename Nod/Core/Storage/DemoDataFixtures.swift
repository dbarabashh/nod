#if DEBUG
    import Foundation

    // swiftlint:disable line_length
    //
    // Demo fixtures are prose: transcript lines, recap bullets, and canned
    // answers all read as written text and can't be wrapped without changing
    // what ships on screen.

    extension DemoData {
        /// One demo session before it's anchored to a launch time: everything
        /// that is fixed about it, with the clock left to `meeting(_:now:)`.
        struct Fixture {
            let id: UUID
            let title: String
            let kind: SessionKind
            let startedAgo: TimeInterval
            let duration: TimeInterval
            let recap: MeetingRecap
        }

        static let coreFixtures: [Fixture] = [
            Fixture(
                id: launchPrep,
                title: "Product Hunt launch — final prep",
                kind: .meeting,
                startedAgo: 2 * 3600,
                duration: 34 * 60,
                recap: MeetingRecap(
                    sections: [
                        section("Launch timing", [
                            bullet(
                                "Locked the launch for Tuesday at 00:01 Pacific so Nod gets a full 24 hours on the leaderboard instead of losing half a day to a late US-morning post",
                                "let's go Tuesday, 00:01 Pacific — that's the whole day on the board"
                            ),
                            bullet(
                                "Avoided Monday because half of Product Hunt's high-signal voters are still catching up on their weekend backlog and engagement is measurably lower",
                                "Monday's a graveyard, everyone's still in inbox-zero mode"
                            ),
                            bullet(
                                "Team agreed to a soft internal freeze on Sunday night — no new build, no copy changes after 9pm — so nothing breaks the morning of"
                            )
                        ]),
                        section("Assets and positioning", [
                            bullet(
                                "Hero GIF will show Nod's floating panel transcribing live next to a real Zoom call, with the participant list visible to prove there's no bot in the room",
                                "the whole pitch is that empty participant list — no 'Nod Notetaker' sitting there"
                            ),
                            bullet(
                                "Gallery locked at six slides: no-bot capture, live transcript, speaker separation, AI summary + action items, chat-with-meeting, and privacy/EU hosting as the closing trust slide"
                            ),
                            bullet(
                                "First comment drafted at ~180 words — opens with the no-bot hook, then EU hosting and native macOS, and closes with the founder's personal email for feedback",
                                "lead with the wedge, not the feature list"
                            ),
                            bullet(
                                "Decided against a promo video for day one; the GIF converts better in the feed and a 60-second video splits attention"
                            )
                        ]),
                        section("Comment and community plan", [
                            bullet(
                                "Founder answers every single comment personally for the first four hours, then hands off to async replies — no canned responses, they read as corporate on PH"
                            ),
                            bullet(
                                "Lined up a private list of ten friendly hunters to seed genuine questions in the first hour so the thread has momentum before it hits the front page"
                            ),
                            bullet(
                                "Prepared three honest talking points for the inevitable 'how is this different from Otter/Fathom' question, all centered on no-bot + EU + native"
                            )
                        ]),
                        section("Open questions", [
                            bullet(
                                "Whether to offer a launch-day discount code or keep pricing clean — worried a discount signals desperation but it does drive first-day conversions"
                            ),
                            bullet(
                                "Whether to cross-post to Hacker News the same day or wait 48 hours to avoid splitting the team's attention"
                            )
                        ])
                    ],
                    actionItems: [
                        action("Send the launch announcement email to the list", deadline: "by Monday noon"),
                        action(
                            "Finalize the first comment, get a second pair of eyes on the copy, and schedule it to pin the moment we go live",
                            deadline: "Monday night"
                        ),
                        action("Confirm all ten hunters can comment within the first hour and send them the launch link privately"),
                        action("Make the call on the discount code and lock the pricing copy either way", deadline: "Monday"),
                        action("Draft the Hacker News post so it's ready if we decide to cross-post")
                    ]
                )
            ),

            Fixture(
                id: designSync,
                title: "Design sync — onboarding revamp",
                kind: .meeting,
                startedAgo: 26 * 3600,
                duration: 41 * 60,
                recap: MeetingRecap(
                    sections: [
                        section("What the usability tests showed", [
                            bullet(
                                "The permission-priming screen — explaining why Nod needs mic and screen recording before the system prompt — cut the denial rate dramatically compared to hitting users with the raw TCC dialog cold",
                                "five out of six people granted it when we told them why first"
                            ),
                            bullet(
                                "Users consistently stalled on the Quit & Relaunch step because the reason line was vague; two testers assumed the app had crashed and force-quit it",
                                "she thought it broke and almost gave up right there"
                            ),
                            bullet(
                                "Nobody read the paragraph of explainer text under the hero — it's too long, and the eye jumps straight to the button"
                            )
                        ]),
                        section("Decisions made", [
                            bullet(
                                "Merge the mic and screen-recording asks into a single guided step with two clearly-labeled toggles instead of two separate full-screen prompts",
                                "one screen, two toggles — stop making them context-switch twice"
                            ),
                            bullet(
                                "Rewrite the relaunch step to state plainly that macOS only picks up the new screen-recording permission after a restart, with a reassuring 'this is normal, your data is safe' line"
                            ),
                            bullet("Cut the hero explainer to a single sentence and let the animated preview carry the explanation")
                        ]),
                        section("Still to resolve", [
                            bullet(
                                "Whether the language picker belongs in onboarding or should default to system language and live only in Settings — leaning toward the latter to shorten the flow"
                            ),
                            bullet(
                                "How to handle the user who denies screen recording outright: a persistent but non-nagging banner, or a dedicated recovery screen"
                            )
                        ])
                    ],
                    actionItems: [
                        action(
                            "Redesign the permission step as one guided screen with two toggles and ship it behind a flag for a follow-up test",
                            deadline: "this week"
                        ),
                        action("Write the new copy for the relaunch reason line and get it reviewed for tone", deadline: "Wednesday"),
                        action("Prototype the denied-permission recovery banner and put it in front of two users"),
                        action("Decide where the language picker lives and update the flow spec")
                    ]
                )
            ),

            Fixture(
                id: oneOnOne,
                title: "1:1 with Sam",
                kind: .meeting,
                startedAgo: 3 * 86400,
                duration: 28 * 60,
                recap: MeetingRecap(
                    sections: [
                        section("Ownership for next sprint", [
                            bullet(
                                "Sam is taking full ownership of the Paddle billing wiring — the checkout flow, the webhook handler, and reconciling subscription state against the entitlements table",
                                "I'll own billing end to end, you don't need to touch it"
                            ),
                            bullet(
                                "Wants to pair on the LLM-proxy quota logic before it ships because the per-user rate limiting has edge cases around trial expiry that are easy to get subtly wrong",
                                "let's pair on the quota math, I don't want to guess on the trial boundary"
                            )
                        ]),
                        section("Concerns Sam raised", [
                            bullet(
                                "Feels the sandbox and production Paddle environments drift too easily and wants a checklist so price IDs never get seeded into the wrong branch again"
                            ),
                            bullet(
                                "Flagged that the current retry toast for failed meeting saves is easy to miss and thinks the outbox deserves a proper status surface in the UI"
                            )
                        ]),
                        section("Open questions", [
                            bullet(
                                "Whether the free trial should be 7 or 14 days — 14 gives users time to hit a second real meeting, but 7 forces the value moment sooner and may convert better"
                            ),
                            bullet("Whether annual billing launches with the paid tier or comes as a fast follow")
                        ])
                    ],
                    actionItems: [
                        action("Send Sam the Paddle sandbox credentials and the current webhook secret", deadline: "tomorrow morning"),
                        action("Book a two-hour pairing session on the proxy quota logic before Friday"),
                        action(
                            "Write the sandbox-vs-production Paddle checklist so price IDs can't cross environments",
                            deadline: "next week"
                        ),
                        action("Decide on 7 vs 14 day trial and lock it in the entitlements config")
                    ]
                )
            ),

            Fixture(
                id: interview,
                title: "Candidate interview — iOS engineer",
                kind: .meeting,
                startedAgo: 5 * 86400,
                duration: 47 * 60,
                recap: MeetingRecap(
                    sections: [
                        section("Strengths", [
                            bullet(
                                "Genuinely strong on AVAudioEngine internals — walked through tap installation, buffer sizes, and the need to convert to 16kHz mono before the VAD without any prompting",
                                "you install the tap, but you have to normalize to 16k mono or the VAD chokes on the sample rate"
                            ),
                            bullet(
                                "Switched fluently from Portuguese to English for the system-design portion and stayed articulate under follow-up pressure",
                                "happy to switch to English — that's where most of my architecture reading is anyway"
                            ),
                            bullet(
                                "Thinks about the UI thread carefully; proposed putting transcription behind a serial queue so the panel never blocks during a long meeting",
                                "the moment audio work touches the main thread, the panel stutters and users notice"
                            )
                        ]),
                        section("Concerns", [
                            bullet(
                                "Noticeably less confident on modern Swift concurrency — reached for completion handlers and DispatchGroup where async/await would have been cleaner, and hesitated when asked about actor isolation"
                            ),
                            bullet(
                                "Limited exposure to ScreenCaptureKit specifically; understood the concept of system-audio capture but hadn't shipped against SCStream before"
                            )
                        ]),
                        section("Recommendation", [
                            bullet(
                                "Advance to the take-home round — the audio-pipeline depth is exactly what the role needs and the concurrency gap is coachable",
                                "the DSP instinct is rare, the async/await stuff we can teach"
                            )
                        ])
                    ],
                    actionItems: [
                        action(
                            "Send the take-home brief scoped to a small SCStream capture task so we can probe the ScreenCaptureKit gap",
                            deadline: "by Thursday"
                        ),
                        action("Share interview notes with the rest of the panel and collect their read before the debrief"),
                        action("Schedule the debrief for early next week once the take-home is back")
                    ]
                )
            ),

            Fixture(
                id: roadmapNote,
                title: "Roadmap ideas",
                kind: .voiceNote,
                startedAgo: 6 * 86400,
                duration: 4 * 60,
                recap: MeetingRecap(
                    sections: [
                        section("Wedge to defend", [
                            bullet(
                                "Multi-speaker diarization is still the one capability nobody in the EU-native segment owns cleanly — source-based me/them is good enough for calls, but true multi-party rooms are the open gap",
                                "diarization is the moat nobody's actually dug yet"
                            ),
                            bullet(
                                "Competitors that do have it lean on cloud pyannote; an on-device sherpa-onnx path would let us keep the privacy story intact while closing the gap"
                            )
                        ]),
                        section("Next headline feature", [
                            bullet(
                                "Action-item carry-over across meetings — recognizing that a task discussed last week came up again today and updating it instead of creating a duplicate — could be the next launch-worthy headline"
                            ),
                            bullet(
                                "Idea: a lightweight reconciliation LLM pass that flags likely continuations for the user to confirm, rather than silently auto-merging"
                            )
                        ])
                    ],
                    actionItems: [
                        action("Spec the action-item continuity epic and break it into a first shippable slice"),
                        action("Prototype on-device diarization with sherpa-onnx and measure the accuracy gap versus cloud pyannote")
                    ]
                )
            )
        ]

        static let extraFixtures: [Fixture] = [
            Fixture(
                id: investorCall,
                title: "Investor update — seed extension",
                kind: .meeting,
                startedAgo: 4 * 3600,
                duration: 38 * 60,
                recap: MeetingRecap(
                    sections: [
                        section("What they pushed on", [
                            bullet(
                                "The lead pressed hard on pricing clarity — a launch-day discount muddies the story, and they'd rather see clean, confident pricing than a promo that reads as doubt",
                                "if you're not sure what it's worth, why would we be?"
                            ),
                            bullet(
                                "Wanted the moat spelled out: what can Otter or Fathom not simply copy in a quarter — features are table stakes, defensibility is the question"
                            )
                        ]),
                        section("What landed", [
                            bullet(
                                "The no-bot, EU-hosted, native-macOS wedge resonated; they explicitly named on-device multi-speaker diarization as the defensible edge if we actually ship it",
                                "the on-device diarization is the thing I'd underwrite — nobody privacy-first has it"
                            ),
                            bullet(
                                "Early trial-conversion signal was enough to keep the conversation warm, but they want the second-meeting activation number before the next update"
                            )
                        ]),
                        section("Open / follow-ups", [
                            bullet(
                                "The pricing narrative — discount or clean — is now blocking two fronts at once: the launch copy and the raise conversation. It has to be decided, not deferred again"
                            ),
                            bullet("Send a one-pager on the diarization roadmap with a concrete on-device accuracy target")
                        ])
                    ],
                    actionItems: [
                        action("Lock the pricing narrative — discount yes or no — before the next investor call", deadline: "this week"),
                        action("Send the diarization roadmap one-pager with an on-device accuracy target", deadline: "Friday"),
                        action("Pull the second-meeting activation number for the next investor update")
                    ]
                )
            ),

            Fixture(
                id: betaFeedback,
                title: "Beta feedback — 3 users",
                kind: .meeting,
                startedAgo: 2 * 86400,
                duration: 33 * 60,
                recap: MeetingRecap(
                    sections: [
                        section("Where users struggled", [
                            bullet(
                                "Two of the three hit the screen-recording permission wall and nearly quit — the exact failure the design sync already flagged, except now it's real users, and the fix is speced but not shipped",
                                "I thought I'd broken something, I almost deleted it"
                            )
                        ]),
                        section("What they asked for", [
                            bullet(
                                "The single most repeated request was telling who said what in a three-person room — multi-speaker, unprompted, from users who'd never heard the word diarization",
                                "it's great for my one-on-ones, but my team standups are a wall of text"
                            )
                        ]),
                        section("Why one churned", [
                            bullet(
                                "One dropped after the trial — said the price felt high before they'd seen team features. Notably, a discount wouldn't have saved them; clarity about what they were paying for would have",
                                "it wasn't too expensive, I just couldn't tell what I was buying"
                            )
                        ])
                    ],
                    actionItems: [
                        action("Ship the merged permission step design sync speced — it's now blocking real users", deadline: "this week"),
                        action("Add multi-speaker to the roadmap one-pager as user-validated demand, not a hunch"),
                        action("Follow up with the churned user about what would actually have converted them")
                    ]
                )
            ),

            Fixture(
                id: growthReview,
                title: "Growth review — activation & trial",
                kind: .meeting,
                startedAgo: 4 * 86400,
                duration: 25 * 60,
                recap: MeetingRecap(
                    sections: [
                        section("The activation metric", [
                            bullet(
                                "The value moment is provably the second real meeting — that's when retention curves flatten. Fourteen-day trials reach it far more often than seven-day ones",
                                "nobody who hits their second meeting churns, basically"
                            )
                        ]),
                        section("But conversion says the opposite", [
                            bullet(
                                "Seven-day trials convert to paid at a higher rate — the urgency works. So activation and conversion point in opposite directions, which means the 7-vs-14 call is a real tradeoff, not a preference",
                                "seven converts better, fourteen activates better — pick your poison"
                            )
                        ]),
                        section("The funnel leak", [
                            bullet(
                                "The single biggest drop-off in the whole funnel is the screen-recording permission step — the same wall the beta users hit and the design sync predicted. It's not a copy problem, it's a structural one"
                            )
                        ])
                    ],
                    actionItems: [
                        action("Decide 7 vs 14 with the activation-vs-conversion tradeoff made explicit, not by gut", deadline: "this week"),
                        action("Instrument the permission-step drop-off precisely so we can measure the onboarding fix")
                    ]
                )
            ),

            Fixture(
                id: competitorTeardown,
                title: "Competitor teardown — Otter / Fathom / OpenWhispr",
                kind: .voiceNote,
                startedAgo: 5 * 86400,
                duration: 18 * 60,
                recap: MeetingRecap(
                    sections: [
                        section("The wedge holds", [
                            bullet(
                                "All three either drop a bot into the call or route audio through US clouds. No-bot, EU-hosted, native macOS is genuinely uncontested — nobody's sitting in our exact spot",
                                "there's literally no one else in the no-bot plus EU corner"
                            )
                        ]),
                        section("The one gap they have and we don't", [
                            bullet(
                                "OpenWhispr shipped real multi-speaker diarization on cloud pyannote. It's the single feature a prospect can point at and say 'they have this, you don't' — and it keeps coming up everywhere else too",
                                "diarization is the only demo where we lose on features, not principles"
                            )
                        ]),
                        section("Pricing benchmark", [
                            bullet(
                                "Everyone clusters at $20–30 a month. Our sub-€20 EU-native price is already the differentiated position — which is one more reason a launch discount actively undersells us"
                            )
                        ])
                    ],
                    actionItems: [
                        action("Prioritize on-device diarization — it's the only feature gap a competitor can name in a demo"),
                        action("Anchor on the sub-€20 EU-native price and stop treating a discount as the growth lever")
                    ]
                )
            )
        ]

        private static func bullet(_ text: String, _ quote: String? = nil) -> MeetingRecap.Bullet {
            MeetingRecap.Bullet(text: text, quote: quote)
        }

        private static func section(_ title: String, _ bullets: [MeetingRecap.Bullet]) -> MeetingRecap.Section {
            MeetingRecap.Section(title: title, bullets: bullets)
        }

        private static func action(_ text: String, deadline: String? = nil) -> MeetingRecap.Action {
            MeetingRecap.Action(text: text, deadline: deadline)
        }
    }
#endif

// swiftlint:enable line_length
