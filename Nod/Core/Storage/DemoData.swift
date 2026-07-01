#if DEBUG
    import Foundation

    /// Local demo toggle — when on, the Supabase-backed stores serve canned
    /// fixtures and swallow every network write, so the whole meeting workflow
    /// (History, summary, transcript, action items, chat) can be walked through
    /// on camera without a single row touching the database.
    ///
    /// DEBUG-only: the whole file compiles out of Release, so it can never ship.
    /// Enable without a rebuild:
    ///     defaults write com.example.nod demo.enabled -bool YES
    /// or pass `NOD_DEMO=1` in the scheme's environment. Disable:
    ///     defaults delete com.example.nod demo.enabled
    enum DemoMode {
        static let defaultsKey = "demo.enabled"

        static var isEnabled: Bool {
            UserDefaults.standard.bool(forKey: defaultsKey)
                || ProcessInfo.processInfo.environment["NOD_DEMO"] == "1"
        }

        static func set(_ enabled: Bool) {
            UserDefaults.standard.set(enabled, forKey: defaultsKey)
        }
    }

    /// Believable, self-consistent sample meetings for the demo video. Built once
    /// (lazily) so ids stay stable across refreshes while the relative timestamps
    /// anchor to launch time.
    enum DemoData {
        static var meetings: [Meeting] {
            bundle.meetings
        }

        static func transcript(for id: UUID) -> [TranscriptRecord] {
            bundle.transcripts[id] ?? []
        }

        static func actionItems(for id: UUID) -> [ActionItem] {
            bundle.actionItems[id] ?? []
        }

        static func chat(for id: UUID) -> [ChatMessage] {
            bundle.chat[id] ?? []
        }

        static var labels: [SessionLabel] {
            bundle.labels
        }

        static var labelAssignments: [UUID: Set<UUID>] {
            bundle.assignments
        }

        /// Stand-in for the server-side vector search — ranks demo transcript
        /// lines by naive query-word overlap so the cross-session / label-scoped
        /// "Ask Nod" chat is grounded in the demo meetings instead of the empty
        /// server index. `meetingID` scopes to one session; `meetingIDs` to a
        /// label's sessions; nil searches every demo meeting.
        static func knowledgeChunks(
            query: String,
            matchCount: Int,
            meetingID: UUID?,
            meetingIDs: [UUID]?
        ) -> [RetrievedChunk] {
            let candidateIDs: [UUID] = if let meetingID {
                [meetingID]
            } else if let meetingIDs, !meetingIDs.isEmpty {
                meetingIDs
            } else {
                meetings.map(\.id)
            }
            let words = Set(
                query.lowercased()
                    .split { !$0.isLetter }
                    .map(String.init)
                    .filter { $0.count > 2 }
            )
            var scored: [(chunk: RetrievedChunk, hits: Int)] = []
            for id in candidateIDs {
                for record in transcript(for: id) {
                    let lower = record.text.lowercased()
                    let hits = words.filter { lower.contains($0) }.count
                    let similarity = 0.55 + min(0.4, Double(hits) * 0.12)
                    scored.append((RetrievedChunk(meetingID: id, content: record.text, similarity: similarity), hits))
                }
            }
            let ranked = scored.sorted {
                $0.hits != $1.hits ? $0.hits > $1.hits : $0.chunk.similarity > $1.chunk.similarity
            }
            return Array(ranked.prefix(matchCount).map(\.chunk))
        }

        static func allActionItems() -> [ActionItem] {
            meetings.flatMap { actionItems(for: $0.id) }
        }

        // MARK: - Fixed identities

        private static let userID = uuid("00000000-0000-0000-0000-0000000000AA")
        private static let launchPrep = uuid("11111111-1111-1111-1111-111111111111")
        private static let designSync = uuid("22222222-2222-2222-2222-222222222222")
        private static let oneOnOne = uuid("33333333-3333-3333-3333-333333333333")
        private static let interview = uuid("44444444-4444-4444-4444-444444444444")
        private static let roadmapNote = uuid("55555555-5555-5555-5555-555555555555")

        private static let launchLabel = uuid("AA000000-0000-0000-0000-000000000001")
        private static let hiringLabel = uuid("AA000000-0000-0000-0000-000000000002")
        private static let oneOnOneLabel = uuid("AA000000-0000-0000-0000-000000000003")
        private static let productLabel = uuid("AA000000-0000-0000-0000-000000000004")

        private static func uuid(_ string: String) -> UUID {
            UUID(uuidString: string) ?? UUID()
        }

        // MARK: - Bundle

        struct Bundle {
            let meetings: [Meeting]
            let transcripts: [UUID: [TranscriptRecord]]
            let actionItems: [UUID: [ActionItem]]
            let chat: [UUID: [ChatMessage]]
            let labels: [SessionLabel]
            let assignments: [UUID: Set<UUID>]
        }

        static let bundle: Bundle = build()

        private static func build() -> Bundle {
            let now = Date()

            let prep = meeting(
                id: launchPrep,
                title: "Product Hunt launch — final prep",
                kind: .meeting,
                startedAgo: 2 * 3600,
                duration: 34 * 60,
                now: now,
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
            )

            let design = meeting(
                id: designSync,
                title: "Design sync — onboarding revamp",
                kind: .meeting,
                startedAgo: 26 * 3600,
                duration: 41 * 60,
                now: now,
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
            )

            let sync = meeting(
                id: oneOnOne,
                title: "1:1 with Sam",
                kind: .meeting,
                startedAgo: 3 * 86400,
                duration: 28 * 60,
                now: now,
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
            )

            let hire = meeting(
                id: interview,
                title: "Candidate interview — iOS engineer",
                kind: .meeting,
                startedAgo: 5 * 86400,
                duration: 47 * 60,
                now: now,
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
            )

            let note = meeting(
                id: roadmapNote,
                title: "Roadmap ideas",
                kind: .voiceNote,
                startedAgo: 6 * 86400,
                duration: 4 * 60,
                now: now,
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

            let meetings = [prep, design, sync, hire, note]

            let transcripts = demoTranscripts(prep: prep, design: design, sync: sync, hire: hire, note: note, now: now)

            var actionItems: [UUID: [ActionItem]] = [:]
            actionItems[launchPrep] = items(for: prep, doneCount: 1, now: now)
            actionItems[designSync] = items(for: design, doneCount: 0, now: now)
            actionItems[oneOnOne] = items(for: sync, doneCount: 1, now: now)
            actionItems[interview] = items(for: hire, doneCount: 0, now: now)
            actionItems[roadmapNote] = items(for: note, doneCount: 0, now: now)

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
                label(productLabel, "Product", "#3B82F6")
            ]
            let assignments: [UUID: Set<UUID>] = [
                launchPrep: [launchLabel],
                designSync: [launchLabel, productLabel],
                oneOnOne: [oneOnOneLabel],
                interview: [hiringLabel],
                roadmapNote: [productLabel]
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

        private static func demoTranscripts(prep: Meeting, design: Meeting, sync: Meeting, hire: Meeting, note: Meeting, now: Date) -> [
            UUID: [TranscriptRecord]
        ] {
            var transcripts: [UUID: [TranscriptRecord]] = [:]
            transcripts[launchPrep] = transcript(for: prep, now: now, lines: [
                (.them, "Okay, before we get too deep — are we still locked on Tuesday, or are people getting cold feet?"),
                (
                    .me,
                    "No cold feet. Tuesday, 00:01 Pacific. If we post at midnight Pacific we get the full twenty-four hours on the leaderboard instead of losing half the day."
                ),
                (
                    .them,
                    "Right, and Monday's a graveyard anyway. Everyone's still digging out of their weekend inbox, nobody's voting with intent."
                ),
                (
                    .me,
                    "Exactly. So Tuesday it is. I want a soft freeze Sunday night though — no new build, no copy changes after nine. I don't want to be debugging the morning we launch."
                ),
                (.them, "Agreed. Let's talk assets. Where did we land on the hero?"),
                (
                    .me,
                    "The GIF. Nod's panel transcribing live, side by side with a real Zoom call, and crucially the participant list is visible so you can see there's no bot sitting in the room."
                ),
                (.them, "That empty participant list is the whole pitch, honestly. That's the thing people screenshot."),
                (
                    .me,
                    "That's why it's slide one. I killed the idea of a launch video — the GIF converts better in the feed and a sixty-second video just splits attention."
                ),
                (.them, "Good call. How many gallery slides total?"),
                (
                    .me,
                    "Six. No-bot capture, live transcript, speaker separation, the AI summary with action items, chat-with-meeting, and then privacy and EU hosting as the closing trust slide."
                ),
                (.them, "Privacy last as the close. I like that. What about the first comment?"),
                (
                    .me,
                    "Drafted, about a hundred and eighty words. It opens with the no-bot hook, then EU hosting and native macOS, and it closes with my personal email for feedback."
                ),
                (.them, "Lead with the wedge, not the feature list. Perfect. Who's manning the thread?"),
                (
                    .me,
                    "Me, personally, every comment for the first four hours. No canned replies — they read as corporate on Product Hunt and people can smell it."
                ),
                (.them, "Do we have hunters lined up to seed the first hour?"),
                (
                    .me,
                    "Ten. A private list. Real questions, not fake praise, so the thread has genuine momentum before it hits the front page."
                ),
                (.them, "And when someone inevitably asks how we're different from Otter or Fathom?"),
                (
                    .me,
                    "Three honest talking points, all no-bot, EU, and native. I'm not going to trash them, I'm just going to be specific about what we do that they structurally can't."
                ),
                (.them, "Okay. The one thing I'm still torn on — discount code, yes or no?"),
                (
                    .me,
                    "Same. A discount drives first-day conversions but it can also signal desperation. Let me sit with it and decide by Monday so the pricing copy is final either way."
                ),
                (.them, "Fair. And Hacker News — same day or wait?"),
                (
                    .me,
                    "Leaning toward waiting forty-eight hours so we're not splitting our own attention. But I'll draft the HN post now so it's ready if we change our minds."
                )
            ])
            transcripts[designSync] = transcript(for: design, now: now, lines: [
                (
                    .me,
                    "So the usability tests came back and the headline is: the priming screen works. When we explain why we need mic and screen recording before the system prompt fires, the denial rate collapses."
                ),
                (.them, "How stark was it?"),
                (.me, "Five out of six granted it when we told them why first. Cold, with the raw TCC dialog, it was closer to half."),
                (.them, "That's a huge swing for one screen of copy. Okay, the bad news?"),
                (.me, "The Quit and Relaunch step. People stall there. Two testers actually thought the app had crashed and force-quit it."),
                (.them, "Oof. Because the reason line is vague?"),
                (
                    .me,
                    "Right. She literally said she thought it broke and almost gave up. We never explain that macOS only picks up screen recording after a restart."
                ),
                (
                    .them,
                    "So we spell it out, and we reassure them their data's fine. Can we also just merge the two permission asks? Making them context-switch to System Settings twice is brutal."
                ),
                (
                    .me,
                    "Yes. That's the big decision from today — one guided screen, two toggles. Mic and screen recording together, clearly labeled, instead of two separate full-screen prompts."
                ),
                (.them, "One screen, two toggles. Much better. What about the hero text — did anyone actually read it?"),
                (.me, "Nobody. Not one person read the explainer paragraph. Their eyes jump straight to the button."),
                (.them, "Then cut it to a sentence and let the preview animation do the talking."),
                (
                    .me,
                    "That's the plan. Two things I still don't have an answer on, though. First, the language picker — does it belong in onboarding at all?"
                ),
                (.them, "I'd default to system language and move it to Settings. Every step we cut from onboarding helps."),
                (
                    .me,
                    "Leaning the same way. And second — the user who flat-out denies screen recording. Persistent banner, or a dedicated recovery screen?"
                ),
                (
                    .them,
                    "Prototype both and put them in front of two people. I don't want to guess on that one, it's the difference between a recoverable user and a churned one."
                )
            ])
            transcripts[oneOnOne] = transcript(for: sync, now: now, lines: [
                (
                    .them,
                    "I want to take billing off your plate entirely. I'll own the Paddle wiring end to end next sprint — checkout, the webhook handler, and reconciling subscription state against the entitlements table."
                ),
                (.me, "That would genuinely unblock me. You sure you want the whole thing?"),
                (.them, "Yeah, you don't need to touch it. One condition though — I want to pair on the proxy quota logic before it ships."),
                (.me, "Happy to. Why the quota specifically?"),
                (
                    .them,
                    "The per-user rate limiting has nasty edge cases around trial expiry. The exact boundary of when a trial flips to blocked is easy to get subtly wrong, and I don't want to guess on the math."
                ),
                (.me, "That's fair, it is fiddly. Let's book two hours this week and work through it together."),
                (
                    .them,
                    "Perfect. While I've got you — the sandbox and production Paddle environments drift way too easily. We seeded a price ID into the wrong branch once already."
                ),
                (.me, "That was a bad afternoon. You want a checklist?"),
                (
                    .them,
                    "A proper sandbox-versus-production checklist, so price IDs physically can't cross environments again. I'll write it."
                ),
                (.me, "Do it. Anything else on your mind?"),
                (
                    .them,
                    "One more. The retry toast for a failed meeting save is really easy to miss. The outbox does its job but the user has no real signal it's pending. I think it deserves a proper status surface."
                ),
                (.me, "Agreed, that's been bugging me too. Let's scope it after billing lands. Oh — trial length. Seven or fourteen days?"),
                (
                    .them,
                    "Genuinely torn. Fourteen gives people time to hit a second real meeting, which is where the value clicks. But seven forces the value moment sooner and might convert better."
                ),
                (
                    .me,
                    "Let me think on it and lock it in the entitlements config. I'll send you the sandbox credentials and the current webhook secret first thing tomorrow so you're not blocked."
                )
            ])
            transcripts[interview] = transcript(for: hire, now: now, lines: [
                (.me, "Thanks for making the time. Let's start hands-on — walk me through how you'd buffer audio taps from the microphone."),
                (
                    .them,
                    "Sure. You install a tap on the input node, but the buffers come in at the hardware sample rate, so the first thing I do is normalize — convert to sixteen kilohertz mono before anything downstream touches it."
                ),
                (.me, "Why sixteen k mono specifically?"),
                (
                    .them,
                    "Because the VAD chokes if you feed it the wrong sample rate, and most speech models are trained at sixteen k anyway. If you skip the conversion you get garbage segmentation. I cache the converter too — allocating one per buffer is a real cost."
                ),
                (
                    .me,
                    "That's exactly right. Let's switch gears to system design — and feel free to do this part in English if that's easier."
                ),
                (
                    .them,
                    "Happy to switch to English, that's where most of my architecture reading is anyway. So, the problem is transcribing a live meeting without the UI ever stuttering, right?"
                ),
                (.me, "Right. Design it for me."),
                (
                    .them,
                    "The cardinal rule is that the moment audio work touches the main thread, the panel stutters and users notice immediately. So I'd put transcription behind a serial queue — capture on the audio thread, hand buffers off, and the UI only ever receives finished text on the main actor."
                ),
                (.me, "What about back-pressure if the model falls behind a fast talker?"),
                (
                    .them,
                    "I'd cap the queue and drop or coalesce the oldest pending segments rather than let latency grow unbounded. A transcript that's two seconds behind is fine; one that's thirty seconds behind is useless."
                ),
                (
                    .me,
                    "Good instinct. Let me push on concurrency a bit — how would you guarantee that the text updates are actually safe to publish to the view?"
                ),
                (
                    .them,
                    "Um — I'd probably wrap the completion in a DispatchQueue.main.async, and use a DispatchGroup to know when a batch is done."
                ),
                (.me, "Would you reach for anything more modern there?"),
                (
                    .them,
                    "You could use async/await, yeah. Honestly I've shipped more with completion handlers, so that's my default reflex, but I know the actor-isolated approach is cleaner. I'd want to lean on that more."
                ),
                (.me, "That's honest, I appreciate it. Have you worked with ScreenCaptureKit directly — SCStream for system audio?"),
                (
                    .them,
                    "Conceptually yes, I understand system-audio capture and why you'd need it for the other side of a call, but I haven't actually shipped against SCStream. That'd be new for me."
                ),
                (.me, "That's useful to know. Okay, last thing — any questions for me?"),
                (
                    .them,
                    "Yeah — how does the team think about on-device versus cloud for the transcription itself? That trade-off is the thing I'd most want to get right."
                )
            ])
            transcripts[roadmapNote] = transcript(for: note, now: now, lines: [
                (.me, "Quick voice note to myself on roadmap direction. Two threads I keep coming back to."),
                (
                    .me,
                    "First, diarization. Source-based me-versus-them is genuinely good enough for one-on-one calls, but true multi-party rooms — three, four people around one mic — is still the gap nobody in the EU-native, privacy-first segment has actually closed. That's the moat nobody's dug yet."
                ),
                (
                    .me,
                    "The competitors who do have real diarization lean on cloud pyannote, which blows up the privacy story. If we can get an on-device sherpa-onnx path to acceptable accuracy, we close the gap without giving up the thing that makes us different."
                ),
                (
                    .me,
                    "Second thread — action-item carry-over across meetings. Right now every meeting's tasks are an island. If I discussed shipping the billing fix last week and it comes up again today, Nod should recognize that's the same task and update it, not create a duplicate."
                ),
                (
                    .me,
                    "I don't want to auto-merge silently though — that'll misfire and erode trust. A lightweight reconciliation pass that flags likely continuations for me to confirm feels right. That could genuinely be the next headline feature. Spec it out."
                )
            ])
            return transcripts
        }

        // MARK: - Builders

        private static func bullet(_ text: String, _ quote: String? = nil) -> MeetingRecap.Bullet {
            MeetingRecap.Bullet(text: text, quote: quote)
        }

        private static func section(_ title: String, _ bullets: [MeetingRecap.Bullet]) -> MeetingRecap.Section {
            MeetingRecap.Section(title: title, bullets: bullets)
        }

        private static func action(_ text: String, deadline: String? = nil) -> MeetingRecap.Action {
            MeetingRecap.Action(text: text, deadline: deadline)
        }

        private static func meeting(
            id: UUID,
            title: String,
            kind: SessionKind,
            startedAgo: TimeInterval,
            duration: TimeInterval,
            now: Date,
            recap: MeetingRecap
        ) -> Meeting {
            let started = now.addingTimeInterval(-startedAgo)
            return Meeting(
                id: id,
                userID: userID,
                createdAt: started,
                startedAt: started,
                endedAt: started.addingTimeInterval(duration),
                title: title,
                kind: kind,
                summary: recap.toMarkdown(),
                recap: recap,
                language: "en",
                deletedAt: nil
            )
        }

        private static func transcript(
            for meeting: Meeting,
            now _: Date,
            lines: [(TranscriptSource, String)]
        ) -> [TranscriptRecord] {
            lines.enumerated().map { idx, line in
                TranscriptRecord(
                    id: UUID(),
                    meetingID: meeting.id,
                    userID: userID,
                    createdAt: nil,
                    source: line.0.rawValue,
                    text: line.1,
                    ts: meeting.startedAt.addingTimeInterval(Double(idx) * 22),
                    idx: idx,
                    speaker: nil
                )
            }
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
