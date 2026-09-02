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
