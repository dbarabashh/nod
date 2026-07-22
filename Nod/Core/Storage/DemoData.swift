// swiftlint:disable line_length
//
// Demo fixtures are prose: transcript lines, recap bullets, and canned
// answers all read as written text and can't be wrapped without changing
// what ships on screen.

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

        private static func matchedAnswer(
            for question: String,
            in table: [(keywords: [String], answer: String)]
        ) -> String? {
            let lowered = question.lowercased()
            return table.first { entry in entry.keywords.contains { lowered.contains($0) } }?.answer
        }

        /// Canned answer for the live in-meeting "Ask" box. A demo recording has
        /// no real transcript behind it, so the model would only ever say
        /// "nothing to answer yet" — here we hand back a believable, grounded
        /// answer keyed loosely to the question, enough to land the "it's
        /// actually listening" moment on camera. Themed around a product-launch
        /// call so it stays consistent with the demo meetings.
        static func liveAskAnswer(for question: String) -> String {
            matchedAnswer(for: question, in: liveAskAnswers) ?? liveAskCoverageAnswer
        }

        private static let liveAskAnswers: [(keywords: [String], answer: String)] = [
            (["action", "to-do", "todo", "to do", "follow up", "follow-up", "next step", "task"], """
            Three things are on the hook so far:

            - **Decide on the discount code** and lock the pricing copy — it's blocking the launch post.
            - **Confirm all ten hunters** can comment in the first hour and send them the link privately.
            - **Draft the Hacker News post** now so it's ready if you decide to cross-post.

            Want me to save these as action items?
            """),
            (["decide", "decision", "agree", "agreed", "conclusion", "land on", "landed"], """
            Here's what's been decided:

            - **Launch Tuesday, 00:01 Pacific** — a full 24 hours on the leaderboard instead of losing half a day.
            - **Hero is the GIF, not a video** — it converts better in the feed and the empty participant list is the whole pitch.
            - **Founder answers every comment personally** for the first four hours — no canned replies.

            > "Lead with the wedge, not the feature list."
            """),
            (["risk", "concern", "worry", "worried", "blocker", "problem", "issue"], """
            Two things still feel unresolved:

            - The **discount code** — it drives first-day conversions but can read as desperation, and nobody's committed either way.
            - Whether to **cross-post to Hacker News the same day** or wait 48 hours to avoid splitting attention.

            Neither blocks going live, but both need a call before Monday.
            """),
            (["discount", "price", "pricing", "code", "coupon", "promo"], """
            On the discount code — it's the one thing still genuinely undecided.

            The case for it: it drives first-day conversions. The case against: on Product Hunt a code can read as desperation, and it muddies otherwise-clean pricing. The room leaned toward deciding by Monday so the launch copy can be finalized either way.

            My read: hold the code back for launch day, and keep it in your pocket for a 48-hour follow-up if momentum stalls.
            """)
        ]

        /// Fallback: a coverage check against the conversation so far — "did we
        /// miss anything?". Grounded in what's already been said, so it reads as
        /// Nod reviewing the transcript rather than recapping it.
        private static let liveAskCoverageAnswer = """
        You've covered the big rocks — launch timing, the hero asset, and the comment plan. A few things haven't come up yet that are worth a beat before you wrap:

        - The **discount code** is still undecided, and the launch copy is blocked on it — don't let it slip past today.
        - Nobody's named a **backup for answering comments** if you get pulled away in the first four hours.
        - You haven't set a plan for a **competitor launching the same day**, or what to do if the thread stalls before it hits the front page.

        Everything else looks locked.
        """

        /// Canned answer for the launcher's "Ask Nod across sessions" — the
        /// headline of this release. The launcher still grounds on the demo
        /// transcripts (via `knowledgeChunks`, so the evidence rows are real
        /// passages from the sample sessions), but the answer itself would need
        /// the proxy, so here we hand back a believable synthesis keyed loosely
        /// to the question. Written to span several demo meetings so the
        /// evidence rows under it come from different sessions on camera.
        static func knowledgeAnswer(for question: String) -> String {
            matchedAnswer(for: question, in: knowledgeAnswers) ?? crossSessionAnswer
        }

        private static let knowledgeAnswers: [(keywords: [String], answer: String)] = [
            (["action item", "to-do", "todo", "to do", "task", "on my plate", "follow up", "follow-up", "next step"], """
            You have a lot open, but three of these are the same decision wearing different hats — I'd start there:

            - **Lock the pricing narrative — discount or clean.** It's a task in *Product Hunt launch*, *and* the investor asked you to close it, *and* the churn interview says a discount wouldn't have helped. One decision unblocks three sessions.
            - **Ship the merged permission step.** Speced in *Design sync*, hitting real users in *Beta feedback*, and the #1 funnel leak in *Growth review*. It's the only item here that's already solved and just sitting unshipped.
            - **Send the diarization one-pager** with an on-device accuracy target — the investor's asking, and *Competitor teardown* just confirmed it's the one gap that matters.

            Then the smaller ones: book the proxy-quota pairing with Sam (Friday), and send the SCStream take-home to the iOS candidate (Thursday).
            """),
            (["undecided", "open question", "still open", "decide", "decision", "pending", "unresolved", "torn", "stuck"], """
            Two of your open decisions have quietly gathered enough evidence to make — you're just not seeing it because it's spread across sessions:

            - **The launch-day discount.** It's been open across *four* conversations for two weeks — launch prep, the investor call, beta feedback, and the competitor teardown. And three of those four argue *against* it: the investor wants clean pricing, the churned user needed clarity not a lower number, and your sub-€20 EU price already undercuts everyone. The evidence is pointing one way.
            - **7- vs 14-day trial.** This one *does* have real tension: Sam leaned 14, but *Growth review* shows 7 converts better while 14 activates better. That's activation vs conversion — a genuine tradeoff to make explicitly, not a gut call.

            The quieter one — where the language picker lives (*Design sync*) — is low-stakes; default it to Settings and move on.
            """),
            (["interview", "candidate", "hire", "hiring", "engineer"], """
            Strong advance-to-take-home on the **iOS engineer** — and there's a nice connection you might have missed:

            - Genuinely deep on AVAudioEngine — walked through tap installation and normalizing to 16 kHz mono before the VAD unprompted, and switched fluently from Portuguese to English mid-interview.
            - Gaps: modern Swift concurrency (reached for completion handlers over async/await) and no shipped ScreenCaptureKit — both coachable.
            - **The connection:** the candidate's own closing question was on-device vs cloud transcription — the exact tradeoff behind your diarization wedge (roadmap, investor call, competitor teardown). This is someone who'd care about the hard problem you actually need solved.
            """),
            (["launch", "product hunt", "hunt", "discount", "pricing", "price"], """
            On the launch and pricing — the pieces are settled *except* the one you keep circling:

            - Going live **Tuesday, 00:01 Pacific**, hero is the **no-bot GIF**, founder answers every comment for four hours (*Product Hunt launch*).
            - **The discount is the only open thread — and the case against it has quietly stacked up across sessions.** The investor wants clean pricing ("if you're not sure what it's worth, why would we be?"), the churned beta user said a discount would've made them trust it *less*, and the competitor teardown shows your sub-€20 EU price is already the differentiated position.
            - My read: hold the code. You're not the cheap option, you're the trustworthy one — and three separate conversations just told you that.
            """),
            (["roadmap", "diarization", "next feature", "moat", "wedge", "multi-speaker", "speaker"], """
            If you're looking for the next headline feature, your own sessions have already voted — **multi-speaker diarization**, and it's not close:

            - It surfaced on its own in *five* separate places: your roadmap note, the candidate's closing question, the investor's "what's the moat," a beta user asking who-said-what in standups, and the competitor teardown.
            - **It's the one feature gap a competitor can name in a demo** — OpenWhispr ships it on cloud pyannote. Everyone else who has it gives up the privacy story to get it; an on-device sherpa-onnx path closes the gap *and* keeps your wedge intact.
            - The investor literally said it's the thing they'd underwrite. It's still just a roadmap idea. That's the gap between where the signal is and where the work is.

            (Runner-up: action-item carry-over across meetings — a real idea, but nowhere near the same pull.)
            """)
        ]

        /// Fallback: the cross-session synthesis — connections no single meeting
        /// shows, ordered by how actionable each one is.
        private static let crossSessionAnswer = """
        I read across all your sessions — here's what you can't see from any single one:

        - **The launch discount has been open in four conversations for two weeks, and the evidence says drop it.** Launch prep, the investor call, beta feedback, and the competitor teardown all touch it — and three of the four argue against a discount. This is your longest-running open decision, and it's already been answered by the room; you just haven't noticed.
        - **Multi-speaker diarization keeps surfacing on its own — five sessions now.** Roadmap, the candidate's question, the investor's "moat," a beta user, the teardown. It's the one thing a competitor can point to that you lack, and the investor said it's what they'd underwrite. Still just a roadmap idea.
        - **The same permission wall is quietly costing you users.** Design sync flagged it, two beta users nearly quit on it, and it's the single biggest drop-off in the growth funnel — yet the fix is speced and unshipped.
        - **Your trial-length call has a hidden contradiction.** Sam leaned 14 days; the growth review shows 7 converts better but 14 activates better. Nobody's made that tradeoff explicit.

        If I had to name one trigger: **ship the onboarding permission fix this week.** It's the only item here that's already solved and just sitting there.
        """

        // MARK: - Live pill fixtures

        /// "Catch me up" (`.hero`) — a short prose read of where the call is right
        /// now. Deliberately state-of-play prose, distinct from Key points'
        /// bullets and Ask's targeted answers.
        static let catchUpAnswer = """
        Right now you're locking launch logistics. The room's aligned on Tuesday at 00:01 Pacific to get a full day on the leaderboard, and the hero asset is settled as the no-bot GIF over a launch video. Still live on the table: whether to run a launch-day discount code, and whether to cross-post to Hacker News same-day or wait 48 hours.
        """

        /// "Key points" (`.keyPoints`) — flat bullet list, decisions first, then
        /// facts, then open questions.
        static let keyPointsAnswer = """
        - Launch is set for Tuesday, 00:01 Pacific — a full 24 hours on the leaderboard.
        - Hero asset is the no-bot GIF, not a launch video.
        - Gallery locked at six slides, with privacy and EU hosting as the closing trust slide.
        - Founder answers every comment personally for the first four hours.
        - Open: run a launch-day discount code, or keep pricing clean.
        - Open: cross-post to Hacker News same-day, or wait 48 hours.
        """

        /// "Suggest reply" (`.suggestReply`) — one line to say next, coaching the
        /// user's own turn in a two-party call.
        static let suggestReplyAnswer = """
        I'd keep pricing clean for launch day — a discount can read as desperation on Product Hunt. Let's hold the code back and revisit it 48 hours in if momentum stalls.
        """

        /// "Suggest follow-up questions" (`.followUp`) — bulleted questions to ask.
        static let followUpAnswer = """
        - Who's the backup on comments if you get pulled away during the first four hours?
        - Are all ten hunters confirmed, or is that still a shortlist?
        - What's the plan if a competitor launches the same day?
        - Should the first comment link straight to the privacy page?
        """

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

        static let userID = uuid("00000000-0000-0000-0000-0000000000AA")
        static let launchPrep = uuid("11111111-1111-1111-1111-111111111111")
        static let designSync = uuid("22222222-2222-2222-2222-222222222222")
        static let oneOnOne = uuid("33333333-3333-3333-3333-333333333333")
        static let interview = uuid("44444444-4444-4444-4444-444444444444")
        static let roadmapNote = uuid("55555555-5555-5555-5555-555555555555")
        static let investorCall = uuid("66666666-6666-6666-6666-666666666666")
        static let betaFeedback = uuid("77777777-7777-7777-7777-777777777777")
        static let growthReview = uuid("88888888-8888-8888-8888-888888888888")
        static let competitorTeardown = uuid("99999999-9999-9999-9999-999999999999")

        static let launchLabel = uuid("AA000000-0000-0000-0000-000000000001")
        static let hiringLabel = uuid("AA000000-0000-0000-0000-000000000002")
        static let oneOnOneLabel = uuid("AA000000-0000-0000-0000-000000000003")
        static let productLabel = uuid("AA000000-0000-0000-0000-000000000004")
        static let investorLabel = uuid("AA000000-0000-0000-0000-000000000005")
        static let growthLabel = uuid("AA000000-0000-0000-0000-000000000006")
        static let feedbackLabel = uuid("AA000000-0000-0000-0000-000000000007")

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
    }
#endif

// swiftlint:enable line_length
