# Agents and the knowledge layer

_Status: releases 1–3 of the plan below are built on the `integrations` branch
and applied to the **sandbox** Supabase branch only (2026-08-31): concepts +
distillation (reading gated by `KNOWLEDGE_READ_ENABLED`, on in sandbox), the
observation ledger and miner (dark), and after-meeting agents with the
recap pattern card — L1 observing, and L2 drafting: a proposal-shaped habit
earns an agent that prints follow-up drafts into the existing "Ready to file"
queue, authored ("Drafted by …") and constrained to that habit's one proposal
type — and L3: a server-enforced standing grant (`agent_approve_proposal`
re-checks agent, grant, type, weekly budget and org policy at the moment of
use), offered from the recap after three untouched approvals, lapsing into
recertification on expiry, with three straight rejections demoting a level.
Server-side runs exist for beats: a pg_cron sweep hands runs still unclaimed
three minutes past their moment to the `beat-worker` edge function, which
answers them with a reduced grounded turn and lets the existing done-trigger
push the phone — the Mac keeps right of first refusal through the unchanged
claim mutex. Not built: cron-agent generalisation (beats remain the cron
agent), org scope, production calibration._
_Last updated: 2026-08-31_

## The change in one sentence

Today Nod remembers what was said. After this, Nod knows what is **true**,
notices what you keep doing **by hand**, and offers to do it for you.

---

## Where we are today

| Entity that exists | What it holds | What it cannot answer |
|---|---|---|
| `meetings`, `meeting_transcripts` | Raw sessions and their text | — |
| `session_embeddings` | Chunks with vectors, start time, kind | "What is true about Atlas?" — only "which passages sound like the question" |
| `entities` | A name and a kind: person, project, topic | Anything **about** the entity. The node has no body |
| `meeting_entities` | Which sessions mentioned which entity | — |
| `people`, `organizations`, `org_members`, `org_policies` | Who exists, in which org, under which rules | — |
| `action_items`, `action_item_transitions` | The checklist and every state change, with who moved it | — |
| `action_proposals` | One offered action, its confidence parts, its evidence, its approval | Whether the user has approved this **same shape** eleven times before |
| `beats`, `beat_runs` | A question on a schedule, and what became of each run | Whether there was anything worth asking about this morning |
| `integrations` catalogue + `ChatToolGate` | Which tools exist, which mutate, and the approval card | — |
| Ambient screen context | What is on screen during a session | Nothing survives the session |

Three gaps, stated plainly:

1. **The entity graph has nodes without bodies.** We know Atlas exists and which
   meetings mentioned it. We know no fact about it.
2. **Beats have a clock but no condition.** A beat fires whether or not anything
   happened.
3. **Approvals are never counted.** Every proposal is judged alone; the eleventh
   identical approval is as much work as the first.

---

## The shape

```
                        ┌──────────────────────────────┐
      MEETINGS  ───────▶│  1. KNOWLEDGE                │
      INTEGRATIONS ────▶│     concepts hung on         │
      AMBIENT (opt-in)─▶│     entities                 │
                        └──────────────┬───────────────┘
                                       │  grounds
                                       ▼
   action_proposals ───┐    ┌──────────────────────────────┐
   action_item_        │    │  4. AGENTS                   │
     transitions       ├───▶│     record + runtime         │
   tool approvals      │    │     trust L0 → L3            │
   beat_runs           │    └──────────────┬───────────────┘
   calendar occurrence │                   │  outcomes
                       │                   ▼
                       │    ┌──────────────────────────────┐
                       └───▶│  2. OBSERVATIONS             │
                            │     one normalised ledger    │
                            └──────────────┬───────────────┘
                                           │  counted by
                                           ▼
                            ┌──────────────────────────────┐
                            │  3. PATTERNS                 │
                            │     support, precision       │
                            └──────────────┬───────────────┘
                                           │  proposes
                                           └──────▶ back to 4
```

The loop closes: agents produce outcomes, outcomes become observations,
observations become patterns, patterns propose agents. The system optimises the
user's work **and its own agents**.

Layers 1 and 2 do not depend on each other. They can be built in parallel.

---

## Layer 1 — Knowledge

**Today.** A question about Atlas runs a vector search over transcript chunks,
boosted by entity name match and a recency prior. It returns the passages that
sound closest. The model reassembles the answer from raw speech every single
time, and pays for it every single time.

**After.** Each entity carries **concepts** — distilled statements, not
transcript excerpts.

```
   entities (exists)          concepts (new)
   ┌───────────────┐          ┌──────────────────────────────────────┐
   │ kind: project │◀────────┤ body:        "Atlas ships 15 Oct"     │
   │ name: Atlas   │          │ evidence:    meeting + line, or       │
   └───────────────┘          │              provider + external key  │
                              │ valid from:  when it became true      │
                              │ valid to:    when it stopped          │
                              │ recorded at: which session taught us  │
                              │ state:       current / superseded /   │
                              │              archived                 │
                              └──────────────────────────────────────┘
```

**Two clocks, not one.** A meeting recorded today can contain a fact about last
month. One timestamp cannot tell "we learned late about an old thing" from "a
new decision was made". `valid from / valid to` is when the fact was true in the
world; `recorded at` is which session taught us. The evidence anchor we already
use on action items and proposals gives us the second clock for free.

**Facts are corrected, not stacked.** When a later session contradicts an earlier
one, the old concept is marked superseded and points at what replaced it. Nothing
is deleted — asked next March what we believed in October, the record answers.
Which version wins is decided by rule, not by asking the model how sure it feels:
newest validity first, then measured confidence, then evidence quality.

**Distillation mostly changes nothing.** Each pass over a finished session decides
per candidate fact: add it, update an existing one, retire one, or — most often —
do nothing. A session that restates what we already know should leave the
knowledge layer untouched.

**Some things never expire.** Decisions and commitments are exempt from pruning.
They are exactly what recall exists for.

**Retrieval becomes two-stage.** Concepts for the entities named in the question
first; transcript chunks only if the concepts were not enough.

**What the user notices.** "What did we decide about pricing?" stops returning
the best-worded discussion and starts returning the decision, with the date and
the meeting it came from — and says so when a later meeting overturned it.

**One thing that gets better for free.** Recall already hunts for contradictions
during a live meeting and treats them as the strongest reason to interrupt.
Today that finding is shown once and forgotten. After this, it also updates the
record.

---

## Layer 2 — Observations

**Today.** The evidence of repetition is real but scattered across five tables in
five shapes. Nothing counts it.

**After.** One normalised ledger with a stable shape, so "what does this person
keep doing" is one question instead of five.

```
   observation
   ├── kind         what happened (proposal approved, tool allowed,
   │                item moved, beat answered, agent ignored)
   ├── subject      what it was about (a proposal type, a provider,
   │                an entity)
   ├── at           when
   └── context key  WHAT MAKES REPETITION VISIBLE:
                    the meeting series, the weekday and hour,
                    the tracker team, the provider and action
```

`context key` is the whole trick. Without it, ten approvals are ten events. With
it, they are one habit.

**Derived, never collected.** The ledger is built from rows the user can already
see and delete. No field goes in that cannot be reconstructed from an existing
row. Delete a meeting and its observations go with it. This is the difference
between a query and a new telemetry stream — and the difference between a
privacy policy that stays true and one that doesn't.

**What the user notices.** Nothing, directly. This layer exists so Layer 3 has
something to count.

---

## Layer 3 — Patterns

**Today.** Nothing. Every approval is judged alone.

**After.** A count, not a guess.

| Rule | Why |
|---|---|
| Same action shape, same context key, at least 3 times | Twice is a coincidence |
| Approved at least 4 times out of 5 offered | A pattern the user keeps rejecting is not a pattern |
| Observed over at least three weeks | A busy fortnight is not a habit |

Arithmetic decides that something is a pattern. The model only writes the
sentence the user reads.

**The insight that removes a whole feature.** "Suggest a process improvement" and
"propose an agent" are the same card. There is no separate optimisation
surface — a suggestion **is** a candidate agent, shown with its evidence.

```
   ┌──────────────────────────────────────────────────────┐
   │  You've filed the same three tasks after standup     │
   │  six Mondays running.                                │
   │                                                      │
   │  Want Nod to draft them for you?                     │
   │                                                      │
   │  Based on: 6 of 7 Mondays · 0 rejected                │
   │  [ See the six ]     [ Not useful ]     [ Try it ]   │
   └──────────────────────────────────────────────────────┘
```

**What the user notices.** Nod starts saying "you keep doing this" — with
receipts they can open.

---

## Layer 4 — Agents

**Today.** A beat is a question on a clock. It has a prompt, a schedule and no
tools. It runs whether or not there is anything to say.

**After.** A beat is the simplest kind of agent. An agent is a **declared
record**, never generated code — the vocabulary it can use is the tool catalogue
we already ship, and nothing new becomes runnable because an agent was created.

```
   agent
   ├── title, prompt        what it is for
   ├── trigger              a clock, the end of a meeting in a series,
   │                        an item changing state, a proposal type appearing
   ├── gate                 a cheap check before spending a full turn
   ├── speaks               always  |  only on change
   ├── tools                a named subset of the catalogue — this agent's
   │                        own scope, not the global preference
   ├── trust                L0 … L3
   ├── budget               runs per day, enforced server-side
   ├── scope                personal  or  organisation — never both
   └── origin               the pattern it came from
```

**The gate.** Most scheduled runs have nothing to report. A cheap check runs
first; only if it says there is something does the agent spend a grounded turn.

**Speaks always, or only on change.** A morning briefing always speaks. A watcher
speaks only when something moved. Anything born from a pattern defaults to
**only on change** — a system that talks constantly gets muted, and then the one
message that mattered is muted too.

**What the user notices.** Silence when there is nothing to say, which is what
makes the noise worth reading.

---

## Trust

An agent earns its way up. It never starts where it ends.

| | Level | What it may do | How it is granted |
|---|---|---|---|
| **L0** | Suggested | Nothing. It is a card | Found by pattern |
| **L1** | Observing | Trigger, read, write an answer into a thread | One tap |
| **L2** | Drafting | Everything above, plus prepare proposals the user approves | One tap; the review card is already the approval |
| **L3** | Standing | Act without asking, inside a named boundary | Explicit, narrow, expiring, revocable |

**L3 is not a checkbox.** It names one provider, one action, constraints on the
parameters, a rate limit and an expiry date. When it expires the agent shows what
it did and asks to be renewed. Recertification is the point of the expiry.

**L3 is unreachable for agents triggered by content.** Transcripts, Slack
messages and tracker comments are text someone else wrote. Today what protects us
is that a person reads every card before anything happens. At L3 that reader is
gone, so a content-triggered agent that writes may not exist.

**Retirement is normal.** Outcomes go back into the ledger. Three ignored outputs
demote an agent a level. Sustained ignoring archives it, with an explanation.
The most useful signal is neither approval nor rejection but **editing before
approving** — the intent was right and the parameters were wrong, which means the
agent should be corrected, not killed. That, too, is a pattern.

---

## Personal and organisation

Both are first-class. An agent belongs to exactly one scope and never migrates
silently.

```
   PERSONAL                          ORGANISATION
   ─────────                         ────────────
   own concepts                      org concepts
   own observations                  org observations
   own patterns                      org patterns
   agent owned by the person         agent owned by a person, approved
                                     by an admin for L3

              ╳  nothing crosses this line  ╳
```

- **Concepts do not cross.** Conversations can be separated and memory still
  leaks between them if the knowledge layer is shared. The boundary is enforced
  by row-level security, not by a prompt.
- **Patterns do not cross.** A habit mined from org activity that produces a
  personal agent is a leak with extra steps.
- **`org_policies.allow_personal_context` extends to agents.** Where an
  organisation has turned personal context off, personal agents are off for its
  members inside it — the same server-owned control, applied to a new object.
- **Org L3 is an admin grant.** A member cannot authorise a bot to write into a
  shared tracker on everyone's behalf. The roles we already carry decide this.

---

## Where agents run

**Today.** A beat runs on whichever Mac is awake. If nobody was awake in the
window, the run expires and the question goes unasked. Honest, but thin for
something that makes a promise.

**After.** Split by what the agent actually needs:

| Agent needs | Runs | If the Mac is asleep |
|---|---|---|
| Retrieval, concepts, reading connected products | Server | Runs anyway. Push delivers it |
| Ambient screen context, local audio | The Mac | Expires, and the UI says so |

Most agents need nothing from the Mac. Those should not depend on it.

---

## Integrations

Eleven products can be connected today: Linear, Google Calendar, Slack, GitHub,
Jira, Notion, Asana, HubSpot, Gmail, Google Drive, Google Ads. Every one of them
touches all four layers, and each layer uses them differently.

### Today

There is one door between Nod and any connected product, and it already holds
two permissions that have nothing to do with agents:

```
   the person connected it   ─┐
                              ├─▶  the door  ─▶  the product
   the organisation allows it ─┘
```

Around it: the tool catalogue only offers tools for products this person
actually connected; every tool is marked as reading or changing; the approval
card is shown for anything that changes something. And one detail that matters
more than it looks — **what a read returns is used for one answer and thrown
away.** Nothing a connected product told us survives the turn.

### Integrations as a source of knowledge

**Today.** Nod asks Linear what the issue says, answers the question, and forgets
both the question and the answer.

**After.** A read that settles something about an entity we already track becomes
a concept, anchored to where it came from.

```
   concept
   ├── body      "Atlas ships 15 Oct"
   ├── evidence  Linear · ATL-412        ← not a meeting, a system of record
   ├── valid     from 12 Aug
   └── state     current
```

Two rules keep this from becoming a junk drawer:

**Not every read is knowledge.** A search that lists twenty issues is
scaffolding, exactly as it is today. A concept is written only when a read
answers something about an entity we are already tracking.

**A product is a system of record, and it wins.** A fact learned from a meeting
is historical — what was said was said. A fact read from Linear is a **cached
view of something that can change tomorrow without telling us.** So concepts
sourced from a product carry a short validity and are re-checked rather than
trusted, and when the product disagrees with the cache, the product is right.
This is the opposite of how we treat a meeting, and the record has to know which
kind it is holding.

### Integrations as a signal

**Today.** The user approves a tool call. The approval is used once and
disappears — only "always allow reads from this product" is remembered, and only
on that Mac.

**After.** Every approval and every refusal at the card becomes an observation,
keyed by product, action and the shape of what was asked. That is what turns
eleven identical approvals into one countable habit.

Two other integration-shaped signals already exist and are currently unread:

- The scheduled reconciles already close items on evidence from a product — a
  task closed because a pull request merged. That is a pattern about the world,
  not about the user, and it is worth knowing which of their work closes itself.
- The calendar already knows which meetings recur. Recurrence is the strongest
  context there is for "the same thing, again".

### Integrations as an agent's tool scope

This is the biggest change, and it is a narrowing, not a widening.

**Today** the question is "may this person use Slack?" — a preference held per
person, per product.

**After** the question is "may **this agent** call **this action**?" Each agent
carries its own named subset of the catalogue. Not *Slack*, but *these two
actions in Slack and nothing else*.

Four checks stack, in this order:

```
   1. Did the person connect this product?        already enforced, server-side
   2. Does their organisation permit it?          already enforced, server-side
   3. Is this action inside this agent's scope?   NEW
   4. Does this agent's trust level allow it?     NEW
      L1 — reads only
      L2 — reads, plus preparing proposals a person approves
      L3 — one named action, inside its grant, until it expires
```

### The one thing that must move to the server

The door authenticates a **person**. For agents it must also authenticate an
**agent**.

Today the rule "an unattended run may not change anything" is kept by handing
that run a catalogue with nothing changeable in it. That works while the client
is the only thing making the decision. At L3 it stops working: the server has to
know which agent is calling, what its scope is, and whether its grant is still
alive — because the door's own reasoning already says a hidden button in a
client is a courtesy, not a gate.

So an agent's calls carry the agent's identity, and checks 3 and 4 happen where
checks 1 and 2 already happen.

### Budgets protect the human, not the invoice

Every agent's calls share the person's own connection and the product's own rate
limit. One agent looping does not just cost money — it can exhaust the quota the
person's live chat is about to need. The per-agent budget is enforced at the same
door, for that reason first.

### When a product goes away

A person disconnects Slack. An organisation bars a product. A token stops
working. All three must behave the same way, and none of them may be loud:

| What happens | The agent | The concepts it wrote | The patterns it fed |
|---|---|---|---|
| Disconnected or barred | Goes dormant, says why once | **Kept**, marked source unreachable | Mining stops, history kept |
| Reconnected | Offers to resume, does not resume itself | Re-checkable again | Mining resumes |

Knowledge is never deleted because a connection lapsed. Someone who disconnects
Slack for a month has not asked us to forget what they learned there.

A check that cannot be carried out refuses. That is already how the door behaves
for a person standing in front of it, and how the scheduled sweeps behave for
people who are not — agents are the second case, and fail closed.

### Organisation agents and whose hands they act with

An org agent files a ticket. The tracker's history will name a person, because a
connection belongs to a person and no product has a concept of "Nod did it".

There are two answers and the choice is not obvious:

| | Through a named owner's connection | Through an organisation service account |
|---|---|---|
| The tracker's history shows | that person | a bot |
| Accountability | clear, but someone's name is on work they did not do | diffuse |
| Provider support | everywhere | varies by product |
| When that person leaves | the agent dies with their access | nothing changes |

Whichever we pick, the rule is the same: **the agent's card says whose hands it
acts with, in the sentence where approval is given.** Anyone approving an org
agent is agreeing to what the audit trail will say, and finding that out later
from a log is not consent.

### Every action's reading-or-changing mark needs a test

The mark that separates a read from a change is the only line this product can
actually defend — it is why an unattended run is safe today, and it is what an
agent's trust level is checked against. Nothing currently pins it. An action
mis-marked as a read hands a standing agent a silent write.

---

## Reference user flow

_A walkthrough, not a specification. One person, ten weeks, so the layers above
can be read as something that happens to someone. The dates and products are
illustrative; the mechanisms are the ones described above, and each beat names
which one is doing the work._

**Setup.** A product lead with Linear, Google Calendar and Slack connected. A
Monday standup and a recurring customer call.

---

**Day 0 — nothing looks different.** Nod records, transcribes, summarises,
proposes tasks. Exactly as today. One invisible change: each approval is now
counted, keyed by _Monday standup + Linear + create issue + team ATL_.
→ _Observations_

**Week 2, chat.** _"When does Atlas ship?"_ The answer is short — **15 October** —
with two sources of different kinds: a meeting from 12 August, and **Linear
ATL-412**. A read from a connected product, which today would live for one turn
and be discarded, is now a concept anchored to the issue it came from.
→ _Knowledge, from an integration_

**Week 3, chat.** The same question. A different answer: **29 October**. Nobody
discussed it — the date moved in Linear. The old date is not gone; it is marked
superseded, and the answer says "changed 21 Sep".
→ _A product is a system of record, and it wins_

**Week 4, mid-call, the notch.** Someone says pricing stays at $49.

```
   This contradicts what you decided
   Pricing moved to $59 for new accounts.
   Decided 26 Aug · Board sync

   [ Open ]  [ Dismiss ]  [ This replaces it ]
```

Today this card would show the closest-sounding passage and be forgotten. Now it
shows the decision with its date, and carries a third action. If the call really
did revert to $49, one tap supersedes the August decision. The interruption stops
being a notification and becomes the moment the record is corrected.
→ _Knowledge + recall_

**Week 6, end of the Monday standup, the recap.** Summary, three items, two
proposals — as always. Two new lines underneath:

```
   Knowledge   2 facts about Atlas updated
   ─────────────────────────────────────────────────────
   You've approved these three the same way six Mondays
   running. Want Nod to draft them for you?
   6 of 7 Mondays · 0 rejected · since 14 Jul

   [ See the six ]   [ Not useful ]   [ Try it ]
```

The suggestion appears where the repetition happens, not in a settings screen.
They tap **Try it** and see the boundary before anything is created:

```
   Monday standup drafts
   Runs     after the Monday standup
   Reads    Linear · your meetings
   Writes   prepares proposals you approve
   Speaks   only when the standup produced items
   Scope    personal
```

→ _Patterns → an agent at L2_

**Week 7, Monday.** The standup ends. The agent wakes, cheaply checks that the
meeting happened and produced items, and drafts the three tasks. They arrive in
the review card the user already knows, with a line saying which agent made them.
Two are right; one has the wrong owner. They fix it and approve — the most useful
signal there is: right intent, wrong parameter.
→ _Gate, L2, outcomes back into observations_

**Week 8 — the organisation.** The same pattern is found across three people on
the team. The candidate appears with an organisation scope, and an admin approves
it, not a member. The card names whose hands it acts with:

```
   Acts through   Nod service account (Linear)
   Approved by    admin
```

Without a service account, that line would carry a person's name — and whoever
approves would be agreeing that the tracker's history says so.
→ _Scope + org grants_

**Week 9 — Slack is disconnected.** A second agent used Slack. It goes dormant
and says so once, rather than failing on every tick. The concepts it wrote from
Slack are kept, marked source unreachable. Disconnecting Slack is not a request
to forget what was learned there.
→ _When a product goes away_

**Week 10 — a standing grant.** The owner has been right for three weeks. The
agent asks:

```
   File issues in Linear · team ATL
   Up to 5 per week · expires in 90 days
   [ Grant ]   [ Keep asking ]
```

One product, one action, one team, a rate, an expiry. Tasks now appear already
filed. The budget here is not about money first: it stops a looping agent from
spending the provider quota the person's live chat is about to need.
→ _L3_

**A quiet Thursday.** The weekly watcher wakes, finds nothing changed, and says
nothing. No notification, no thread, no cost. That silence is what makes the rest
worth reading.
→ _Speaks only on change_

**Month four.** A different agent, born from a pattern that stopped being true,
is ignored a fourth time. It demotes itself, then archives, and says why. Nobody
had to tidy up.
→ _Retirement_

**Day ninety.** The grant expires. The agent shows its ninety days — what it
filed, what was edited, what was rejected — and asks to be renewed. It is
renewed, narrower.
→ _Recertification_

---

### What the person ended up with

| | Before | After |
|---|---|---|
| A question in chat | a retelling of what was discussed | what is true **now**, since when, and what replaced it |
| Data from connected products | lived for one turn | becomes knowledge with a live source |
| The notch on a contradiction | showed it and forgot | **corrects the record in one tap** |
| Repeated work | done by hand every time | noticed, evidenced, and offered |
| Permissions | global, per product | per agent, per action, with an expiry |
| An agent that stopped being useful | — | retires itself |
| Silence | — | exists |

No step in this walkthrough sends the person to a new settings screen. It all
happens where they already work: the notch, the recap, the chat.

---

## What this is not

- Not an agent that writes its own code. An agent is a record made of words the
  system already knows; nothing new becomes executable because one was created.
- Not an agent with a computer. No terminal, no filesystem, no container. The
  boundary that matters is which connected products an agent may reach, and that
  boundary already exists.
- Not an agent that acts unasked by default. Every level below the last one ends
  at a card a person taps.

---

## Open decisions

These change product boundaries and belong in a decision record before code:

- [ ] Moving read-only agents off the Mac and onto the server
- [ ] The observations ledger as derived data — the privacy binding and whether
      it is opt-in
- [ ] Ambient screen context as a source for durable knowledge, which is a
      different promise from ambient helping in the current meeting, and needs
      its own consent
- [ ] Whether personal agents are available at all inside an organisation that
      has turned personal context off
- [ ] Agent identity at the integration door, so scope and grant are checked
      where the connection and the org policy already are
- [ ] Whether an organisation agent acts through a named owner's connection or
      an organisation service account, and how that is shown to whoever
      approves it

---

## Implementation plan

_Everything above says what and why. This section says how, in what order, and
what existing users experience at each step. Mechanics borrowed from the
reviewed open-source projects are credited inline; the schema is described at
field level but authored, as always, as migrations under `supabase/migrations/`._

### The one rule for shipping this

We release into an installed base. Existing users must feel exactly one thing:
**the quality of answers went up.** Everything else is invisible until they act
on a card. Concretely:

- Every migration is expand-only. Nothing is dropped, renamed or tightened in
  any release described here; contract steps get their own linked cleanup
  issues with measured retirement gates, per `backward-compatibility.md`.
- Beats keep working untouched for every released client. No beat is migrated,
  moved or re-run by anything in this plan without the user acting in a new UI.
- No consent, entitlement or approval meaning is widened by migration. The
  strictest current behaviour stays the default for everyone who upgrades into
  a new setting existing.
- A client that predates a feature simply doesn't render it. Nothing it already
  renders changes shape.

### Positions this plan takes

The open decisions above still need decision records in the playbook, but a
plan cannot hedge. The defaults built here:

| Fork | Position | Why |
|---|---|---|
| Where L1 agents run | Server | `pg_cron` and `pg_net` are already installed and already drive beat enqueueing; the Mac adds nothing a read-only agent needs |
| Org agents | **Deferred to the last phase** | Connections are per-person today; the acting-identity fork is unresolved; personal scope exercises every mechanism without it |
| Observations | Derived views over existing rows, no new collection | Keeps `privacy.md` §3.8 literally true; the policy binding is still written before any UI mentions the ledger |
| Ambient as durable knowledge | Out of scope entirely | Different promise, own consent, own decision record, later |

### What each reviewed project contributed

| Mechanism in this plan | Borrowed from |
|---|---|
| Two clocks on a concept, supersede-not-delete | Graphiti's bitemporal model, rebuilt as columns and a `btree_gist` exclusion instead of a graph database |
| Add / update / retire / no-op distillation decision | Mem0's extraction loop |
| Deterministic supersede ordering, never the model's confidence | the freshness paper's recipe |
| `speaks: only on change` as the pattern-born default; pruning exemptions | n8n-claw |
| The gate contract (cheap check first, tiny payload if waking) | NanoClaw script gates, as a SQL predicate instead of Bash |
| Per-agent tool scope as an object, not a global preference | Pydantic AI Backend rulesets |
| Agent identity enforced at the door, credentials never reaching the caller | OneCLI's gateway, kept at action level where ours already is |
| A test pinning every action's reading-or-changing mark | NanoClaw's integration-point testing doctrine |

### Schema, expand-only

Two extensions enabled first: `btree_gist` (exclusion constraints over time
ranges) and `pg_jsonschema` (validating agent specs). Both ship in the Supabase
image; neither is exotic.

**`concepts`** — the body of a node in the existing entity graph.

| Column | Holds |
|---|---|
| `id`, `user_id`, `entity_id` | ownership and the `entities` row it hangs on |
| `org_id` | null until the org phase; RLS is per-user until then |
| `kind` | `fact` / `decision` / `commitment` / `preference` — decisions and commitments are the pruning-exempt kinds |
| `body` | one distilled statement |
| `source` | `meeting` / `integration` / `chat` — an integration-sourced row is a cached view and is re-checked, never trusted |
| `evidence` | meeting + transcript index, or provider + external key — the same anchors `action_items` and `action_proposals` already carry |
| `valid_from`, `valid_to` | when the fact was true in the world |
| `recorded_at` | which session taught us |
| `state`, `superseded_by` | `current` / `superseded` / `archived`, and by what |
| `confidence` | measured parts, the same discipline as `confidence_parts` on proposals |
| `embedding` | gte-small, embedded server-side by the proxy like every chunk today |

An exclusion constraint keeps two `current` rows about the same claim from
holding overlapping validity — the invariant lives in the engine, not in code.
Deleting a meeting cascades through its evidence. Every grant explicit, RLS
from the first migration.

**`observations`** — a view first, materialized only if it earns it. Reads
`action_proposals`, `action_item_transitions`, `beat_runs`, tool-approval rows
(below) and calendar recurrence into one shape: `kind`, `subject`, `at`,
`context_key`. Being derived, deletion follows the source rows by construction.

**`tool_approvals`** — the one genuinely new stream: each allow/deny at the
approval card, with provider, action names and parameter shape (never values).
Today this signal evaporates; it is also what moves the "always allow"
preference from one Mac's local defaults to rows every device and the server
can see. Local defaults keep working; server rows win only when stricter or
newer — nobody's standing choice is widened by upgrading.

**`pattern_candidates`** — `context_key`, support, precision, window, example
observation ids, status (`candidate` / `offered` / `accepted` / `dismissed`).
Written by the miner, read by the recap card.

**`agents`**, **`agent_runs`**, **`agent_grants`** — the record, its runs, and
standing permissions:

- `agents`: title, prompt, `trigger` and `gate` as JSON validated by
  `pg_jsonschema` against a versioned spec, `speaks` (`always` / `on_change`),
  `tools` (named actions, checked against the catalogue), `trust` (`l0`–`l3`),
  `budget`, `scope` (`personal` now, `org` later), `origin_pattern`,
  `spec_version`, `status` (`active` / `dormant` / `demoted` / `archived`).
- `agent_runs`: the `beat_runs` shape reused — due, claimed, done, failed,
  expired, plus `gate_skipped`; same claim semantics, so the "one runner wins"
  property is inherited, not reinvented.
- `agent_grants`: agent, provider, action, parameter constraints, rate limit,
  `expires_at`, `granted_by`, `revoked_at`. A grant is a row, so revocation and
  expiry are queries, and recertification is "the row expired".

### Contracts and versioning

- The agent spec carries `spec_version`. A client that doesn't know a version
  **refuses to run that agent** — stricter than the `unknown`-status degradation
  beats use, because a half-understood agent still acts. Old clients simply
  never fetch agents at all.
- Beats and agents coexist indefinitely. The new client's beat UI creates
  agents; converting an existing beat is a user action that disables the beat
  and creates the agent in one transaction — never both live, so a legacy Mac
  claiming beat runs and the server running agents cannot double-fire the same
  question. This is the first mixed-version test.
- Mixed-version tests, per the supabase rule, start from the previous
  production schema: old client + concepts tables present; old client + a beat
  the new client converted; new client + no grants; server tick + an old client
  awake at the same minute.
- Beat retirement, if ever, is its own cleanup issue behind observed zero
  legacy traffic. Not part of this plan.

### The distillation pipeline

Runs server-side in the proxy, after the summary pass it already performs — one
additional bounded call per session, not a new class of cost.

1. **Extract** candidate statements about entities the session's existing
   entity-extraction already found. No new entity discovery in v1.
2. **Decide** per candidate against that entity's current concepts: add,
   update, retire, or — the expected majority — no-op.
3. **Supersede deterministically**: newest validity wins, then measured
   confidence, then evidence quality. The model proposes; the rule disposes.
4. **Cap** concepts written per session; a session trying to exceed the cap is
   a distillation bug, not a productive meeting.

Quality gate before anyone sees it: a golden set of past sessions with
hand-checked expected concepts, and a **dark period** — concepts are written
but retrieval doesn't read them until precision on the golden set clears the
bar. Turning reading on is a server-side flag, not a release.

### Retrieval

A new match function for concepts beside the existing chunk match — an added
function, not a changed signature, so released clients keep the exact path they
have. The proxy consults concepts for entities named in the question first,
falls back to chunks, and blends exactly as the entity boost does today. The
recall prompt gains the concept as a candidate source; the "this replaces it"
action is new-client UI over a plain state transition.

### The runtime

- **Server tick**: `pg_cron` fires, `pg_net` wakes an `agent-run` edge
  function — the scheduler stays ten dumb lines so a self-hosted future swaps it
  for a timer without touching logic. The function claims due runs exactly as
  `claim_beat_run` does, evaluates the gate (a read-only SQL predicate with a
  statement timeout), and either completes the run as `gate_skipped` or
  executes the grounded turn.
- **Mac runtime**: the existing beat runner generalises to run Mac-bound agents
  only. Its sleep/wake behaviour, serial execution and entitlement gating carry
  over unchanged.
- **Agent identity at the door**: every integration call made for an agent
  carries the agent's id alongside the user's token. `integration-action` loads
  the row and enforces, server-side, in order: connection exists, org permits,
  action within the agent's `tools`, trust level allows it, grant alive,
  budget remaining. The client-side card keeps doing exactly what it does for
  humans; for agents the server is the gate, because a hidden button is a
  courtesy.
- **Budget**: counted per agent per day at the door, so a looping agent is
  stopped before it spends the provider quota the person's live chat needs.

### Cost

One distillation pass per session, capped. Concept embeddings are the same
per-chunk cost we already pay, at far lower volume. Integration-sourced
concepts are re-checked **only when something already reads the provider** — a
chat tool call, a scheduled reconcile — never by their own polling loop in v1.
Agent turns are bounded by the gate, `speaks: on_change`, and the budget.
Nothing here scales with time; everything scales with use.

### The calibration gate

Before any pattern card ships, the miner runs dark against production-shape
data: the distribution of support and precision over real `action_proposals`
and transitions decides the thresholds — and whether the card ships at all. If
repetition of the assumed density doesn't exist, layers 3 and 4 stop here at
the cost of a query, and layer 1 has already paid for itself.

### Order of work

| Release | Ships | Existing users feel |
|---|---|---|
| **1 — Knowledge** | Extensions, `concepts`, distillation (dark, then on), two-stage retrieval, recap "knowledge" line, the upgraded recall card | Answers carry dates, survive contradictions, and improve. Nothing else |
| **2 — Ledger, dark** | `tool_approvals`, `observations`, the miner with no UI; the calibration gate decides thresholds | Nothing |
| **3 — Agents, personal** | `agents` + runs, L0 pattern card in the recap, L1/L2, gates, the beat-conversion path, playbook records and policy bindings landed | The card appears only for people whose own history earned it |
| **4 — Standing** | `agent_grants`, L3 with expiry and recertification, server-side L1 runs, then the org scope behind its decision record | Asked-for autonomy, never assumed |

Each release is independently shippable and independently abandonable; nothing
in an earlier one assumes a later one exists.
