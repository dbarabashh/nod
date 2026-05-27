# Recording & Consent

_Last updated: 2026-05-27_

> **Nod is in private beta**, built by an individual developer. The
> guidance below reflects how the product actually behaves today; the
> legal rules of where you live always take precedence over anything on
> this page.

Nod records and transcribes meetings on your Mac. Recording a conversation —
even one you're participating in — is regulated by law, and the rules differ
significantly by country and by US state. **You are responsible for obtaining
consent from everyone on the call before you start recording with Nod.**

This page is a practical guide. It is not legal advice — when in doubt,
consult a lawyer in your jurisdiction.

---

## What Nod does (and doesn't do)

- Nod runs entirely on your Mac. We do **not** post a notification into the
  Zoom / Google Meet / Microsoft Teams chat for you. We don't have access to
  the chat — there is no Nod bot in the meeting.
- Nod shows you a one-time **consent reminder** before your very first
  recording. Every acknowledgement is recorded in an audit log
  (`consent_acknowledgements` table) tied to your account, the exact wording
  you saw, and your app version.
- **You** must inform the other participants. The simplest path is to tell
  them verbally at the start of the call, or paste the template message
  below into the meeting chat.
- Audio is never stored — it is transcribed in ~5-second chunks and
  immediately discarded. Only the transcript and the AI-generated summary
  remain. See [Security & Privacy](./security.md) for details.

---

## A simple rule of thumb

Even where the law allows one-party consent, **best practice is to tell
everyone on the call that you're recording**. It's professional, it builds
trust, and it sidesteps most jurisdictional ambiguity.

## Consent regimes — quick reference

Recording laws fall into two broad regimes:

**One-party consent** — only one party to the conversation (which can be
you) needs to consent. Examples (non-exhaustive): the United Kingdom for
personal use, most Canadian provinces, the majority of US states.

**All-party (two-party) consent** — every participant must be informed and
consent. Examples: California, Florida, Illinois, Maryland, Massachusetts,
Montana, Nevada, New Hampshire, Pennsylvania, Washington, plus much of the
European Union under GDPR for any recording that captures personal data of
non-consenting participants.

When participants are in **different jurisdictions**, the most restrictive
rule usually applies — if even one person is in an all-party state, treat
the call as all-party.

> **This is a simplified summary, not legal advice.** Laws change. Edge
> cases exist (workplace recordings, recordings used as evidence, etc.).
> If your business depends on getting this right — talk to a lawyer.

---

## Template participant notice

Paste this in the meeting chat at the start of the call:

> _"Heads up — I'm using Nod to take AI-generated notes for this meeting.
> It transcribes the conversation locally on my Mac and produces a summary
> for me afterwards. No audio is stored. If you'd prefer I don't record,
> just let me know and I'll turn it off."_

Or, in Ukrainian:

> _"Невелика примітка — я використовую Nod, щоб робити AI-нотатки з цієї
> зустрічі. Він транскрибує розмову локально на моєму Mac і робить для
> мене коротке summary. Аудіо ніде не зберігається. Якщо не хочеш, щоб я
> записував — просто скажи і я вимкну."_

---

## What participants can ask for

If a meeting participant wants their data removed from your Nod history,
they should contact **you** (the recorder) — Nod doesn't have a relationship
with them. You can:

1. **Delete the meeting** from the app. It goes to a 30-day trash, then it
   is permanently and automatically purged from our database.
2. **Email dbarabashdev@gmail.com** if you need confirmation that a specific
   meeting has been deleted.

If you are a participant who has been recorded **without** your consent and
wants the recording removed, contact **dbarabashdev@gmail.com** with the name and
email of the Nod user, the approximate date/time of the meeting, and a
description. We will take reasonable steps to identify and assist with
deletion.

---

## Automatic in-meeting notice — on the roadmap

We're evaluating an opt-in feature that copies a consent message to your
clipboard (or pastes it into the meeting chat via accessibility automation)
when you press record. If this is important to your team, let us know at
**dbarabashdev@gmail.com**.

---

Questions? **dbarabashdev@gmail.com**.
