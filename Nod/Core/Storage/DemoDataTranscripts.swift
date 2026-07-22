#if DEBUG
    import Foundation

    // swiftlint:disable line_length
    //
    // Demo fixtures are prose: transcript lines, recap bullets, and canned
    // answers all read as written text and can't be wrapped without changing
    // what ships on screen.

    extension DemoData {
        static func demoTranscripts(_ byID: [UUID: Meeting]) -> [UUID: [TranscriptRecord]] {
            var transcripts: [UUID: [TranscriptRecord]] = [:]
            for entry in transcriptLines {
                guard let meeting = byID[entry.meeting] else { continue }
                transcripts[entry.meeting] = transcript(for: meeting, lines: entry.lines)
            }
            return transcripts
        }

        private static func transcript(
            for meeting: Meeting,
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

        private static let transcriptLines: [(meeting: UUID, lines: [(TranscriptSource, String)])] = [
            (launchPrep, [
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
            ]),
            (designSync, [
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
            ]),
            (oneOnOne, [
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
            ]),
            (interview, [
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
            ]),
            (roadmapNote, [
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
            ]),
            (investorCall, [
                (.them, "Before we talk numbers — I want to understand the pricing. Are you running a launch discount or not?"),
                (
                    .me,
                    "Still deciding. It'd drive first-day conversions, but I hear you that it muddies the story."
                ),
                (
                    .them,
                    "It does more than muddy it. If you're not sure what it's worth, why would we be? Clean, confident pricing is the signal I want to see."
                ),
                (.me, "That's fair. It's honestly been the one open thread for two weeks now."),
                (.them, "Then close it. Now — the moat. What can Otter or Fathom not just copy in a quarter?"),
                (
                    .me,
                    "No bot in the room, EU hosting, native macOS. And the one nobody privacy-first has: on-device multi-speaker diarization. That's the defensible edge."
                ),
                (
                    .them,
                    "The on-device diarization is the thing I'd underwrite. Features are table stakes — that's the part I can't see anyone copying without giving up their privacy story. Are you shipping it?"
                ),
                (.me, "It's on the roadmap. I'll send you a one-pager with a concrete on-device accuracy target."),
                (.them, "Do. And what's your trial conversion looking like?"),
                (
                    .me,
                    "Early but promising. The number I want to bring you next time is second-meeting activation — that's the real leading indicator."
                ),
                (.them, "Agreed, that's the one I'd watch. Bring me that and the pricing decision and we keep talking.")
            ]),
            (betaFeedback, [
                (.me, "Thanks for testing it this week. Be brutal — where did it trip you up?"),
                (
                    .them,
                    "Honestly? The screen recording permission. I thought I'd broken something, I almost deleted it. There was a step where it just… stopped, and I didn't know why."
                ),
                (.me, "You're the second person this week to say that. It's the relaunch step, isn't it."),
                (
                    .them,
                    "Yeah. Once I got past it, it was great. The transcription is genuinely better than what I was using."
                ),
                (.me, "What's the one thing you wished it did that it doesn't?"),
                (
                    .them,
                    "Tell me who said what. It's great for my one-on-ones, but my team standups are a wall of text — three people and I can't tell them apart."
                ),
                (.me, "That keeps coming up. Noted, and it's already where my head is on the roadmap."),
                (
                    .me,
                    "One of the other testers churned after the trial — said the price felt high. Did it feel expensive to you?"
                ),
                (
                    .them,
                    "It wasn't too expensive, I just couldn't tell what I was buying. If anything a discount would've made me trust it less. I needed to see the team features, not a lower number."
                )
            ]),
            (growthReview, [
                (.me, "Let's settle the trial-length question with data instead of opinions. What does activation say?"),
                (
                    .them,
                    "Clear signal — the value moment is the second real meeting. Retention flattens the second someone hits it. And fourteen-day trials reach that second meeting way more often than seven-day ones."
                ),
                (.me, "So fourteen wins?"),
                (
                    .them,
                    "Not so fast. Conversion tells the opposite story. Seven-day trials convert to paid at a higher rate — the urgency actually works. Seven converts better, fourteen activates better. Pick your poison."
                ),
                (.me, "So it's a genuine tradeoff, not a preference. That's the thing to decide explicitly."),
                (
                    .them,
                    "Right. And whichever way you go, there's a bigger leak upstream. The single biggest drop-off in the whole funnel is the screen-recording permission step."
                ),
                (.me, "The same wall the beta users hit. And design flagged it a month ago."),
                (
                    .them,
                    "Same one. This isn't a copy problem, it's structural. Fix that and both trial variants improve — you're arguing about the trial while the real leak is one screen earlier."
                )
            ]),
            (competitorTeardown, [
                (.me, "Voice note — competitor teardown. Went deep on Otter, Fathom, and OpenWhispr this afternoon."),
                (
                    .me,
                    "Headline: the wedge holds. All three either drop a bot into the call or route audio through US clouds. There's literally no one else in the no-bot plus EU corner. That's ours, uncontested."
                ),
                (
                    .me,
                    "But there's one gap, and it's the same one that keeps coming up everywhere. OpenWhispr shipped real multi-speaker diarization on cloud pyannote. It's the only demo where we lose on features, not principles."
                ),
                (
                    .me,
                    "Every signal this month points at diarization — the roadmap, the investor call, the beta users, now the teardown. If a competitor can name one thing we don't have, that's it. On-device is how we close it without giving up privacy."
                ),
                (
                    .me,
                    "Pricing: everyone clusters at twenty to thirty dollars a month. Our sub-twenty-euro EU-native price is already the differentiated position. Which is one more reason a launch discount actively undersells us — we're not the cheap option, we're the trustworthy one."
                )
            ])
        ]
    }
#endif

// swiftlint:enable line_length
