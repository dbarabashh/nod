import { adminClient } from "./supabase.ts";
import { isObject, json } from "./http.ts";
import { completeOnce } from "./complete.ts";
import { embedText } from "./search.ts";
import { getTranscript } from "./meetings.ts";

// The distiller: one finished session in, a handful of durable statements
// about already-known entities out. It writes the knowledge layer; the search
// path below reads it. Reading ships dark — `KNOWLEDGE_READ_ENABLED` decides
// when retrieval may consume what distillation has been writing, so quality
// can be judged on real sessions before a single answer depends on it.

// Haiku-class by default: the hard part of distillation is restraint, not
// prose, and the expected output is usually empty. Overridable per branch the
// same way every other task model is.
const DISTILL_MODEL = Deno.env.get("DISTILL_MODEL") ?? "anthropic/claude-haiku-4.5";

// A session trying to write more than this is a distillation bug, not a
// productive meeting.
const MAX_OPS = 12;
// Keeps a three-hour session from becoming a six-figure prompt. Lines beyond
// the cap are dropped from the middle: openings carry introductions and ends
// carry decisions.
const MAX_TRANSCRIPT_CHARS = 24_000;

const MAX_CONCEPTS_IN_ANSWER = 6;

export function knowledgeReadEnabled(): boolean {
    return Deno.env.get("KNOWLEDGE_READ_ENABLED") === "true";
}

interface EntityRow {
    id: string;
    name: string;
    kind: string;
}

interface ConceptRow {
    id: string;
    entity_id: string;
    kind: string;
    claim_key: string;
    body: string;
    valid_from: string;
    meeting_id: string | null;
    provider: string | null;
    external_key: string | null;
    similarity: number;
}

interface DistillOp {
    op: "set" | "retire";
    entity: string;
    kind: string;
    claim_key: string;
    body?: string;
    evidence_idx?: number;
    valid_from?: string;
}

export async function handleDistill(payload: unknown, userId: string): Promise<Response> {
    if (!isObject(payload) || typeof payload.meeting_id !== "string") {
        return json({ error: "distill requires { meeting_id }" }, 400);
    }
    const meetingId = payload.meeting_id;
    const admin = adminClient();

    const transcript = await getTranscript(admin, userId, meetingId).catch(() => null);
    if (!transcript) return json({ error: "meeting not found" }, 404);

    const entities = await meetingEntities(admin, userId, meetingId);
    // No known entities means nothing to hang a fact on. Entity extraction is
    // the client's pass and runs before this one; a session it found nobody in
    // is genuinely not distillable, and saying so cheaply beats a model call
    // that can only invent.
    if (entities.length === 0) {
        await stampDistilled(admin, meetingId);
        return json({ added: 0, updated: 0, retired: 0, noop: 0 }, 200);
    }

    const existing = await currentConcepts(admin, entities.map((e) => e.id));
    const ops = await proposeOps(userId, transcript, entities, existing);
    if (ops === null) return json({ error: "distillation failed" }, 502);

    const byName = new Map(entities.map((e) => [e.name.trim().toLowerCase(), e]));
    const counts = { added: 0, updated: 0, retired: 0, noop: 0 };
    for (const op of ops.slice(0, MAX_OPS)) {
        const entity = byName.get(op.entity?.trim().toLowerCase() ?? "");
        // An entity the session never established is not ours to write about —
        // whatever the model thought it saw.
        if (!entity || !op.claim_key) continue;
        if (op.op === "retire") {
            const { error } = await admin
                .from("concepts")
                .update({ state: "archived", valid_to: new Date().toISOString(), updated_at: new Date().toISOString() })
                .eq("user_id", userId)
                .eq("entity_id", entity.id)
                .eq("claim_key", op.claim_key)
                .eq("state", "current")
                // Decisions and commitments are pruning-exempt: they are what
                // recall exists to bring back, and a model cannot retire them.
                .in("kind", ["fact", "preference"]);
            if (!error) counts.retired += 1;
            continue;
        }
        if (typeof op.body !== "string" || op.body.trim().length === 0) continue;
        const kind = ["fact", "decision", "commitment", "preference"].includes(op.kind) ? op.kind : "fact";
        let embedding: number[] | null = null;
        try {
            embedding = await embedText(op.body);
        } catch {
            // A concept without a vector is still reachable through its
            // entity; failing the whole distillation over one embed is not.
        }
        const { data, error } = await admin.rpc("apply_concept", {
            p_user_id: userId,
            p_entity_id: entity.id,
            p_kind: kind,
            p_claim_key: op.claim_key.slice(0, 80),
            p_body: op.body.slice(0, 500),
            p_source: "meeting",
            p_meeting: meetingId,
            p_evidence_idx: typeof op.evidence_idx === "number" ? Math.floor(op.evidence_idx) : null,
            p_embedding: embedding,
            p_valid_from: validFrom(op.valid_from),
        });
        if (error) {
            console.warn(`apply_concept failed for ${entity.name}/${op.claim_key}: ${error.message}`);
            continue;
        }
        const decision = Array.isArray(data) && data[0]?.decision;
        if (decision === "added") counts.added += 1;
        else if (decision === "updated") counts.updated += 1;
        else counts.noop += 1;
    }

    await stampDistilled(admin, meetingId);
    console.log(`distill user=${userId} meeting=${meetingId} entities=${entities.length} ops=${ops.length} ` +
        `added=${counts.added} updated=${counts.updated} retired=${counts.retired} noop=${counts.noop}`);
    return json(counts, 200);
}

// Coverage is the server's fact: the stamp is what lets the client's backfill
// ask "which recent sessions still owe a pass" as one indexed question — and
// what stops a session that honestly yielded nothing from being re-distilled,
// at model-call prices, on every launch forever.
async function stampDistilled(admin: ReturnType<typeof adminClient>, meetingId: string): Promise<void> {
    const { error } = await admin
        .from("meetings")
        .update({ distilled_at: new Date().toISOString() })
        .eq("id", meetingId);
    if (error) console.warn(`distilled_at stamp failed (non-fatal): ${error.message}`);
}

// Stage one of retrieval, consulted by `handleSearch`: current concepts for
// the entities the question names. Entity-scoped on purpose — a question that
// names nothing we track gets no concepts and loses nothing, while a question
// about Atlas gets Atlas's facts before any transcript chunk.
export async function conceptsForSearch(
    admin: ReturnType<typeof adminClient>,
    userId: string,
    query: string,
    embedding: number[],
): Promise<ConceptRow[]> {
    if (!knowledgeReadEnabled()) return [];
    try {
        const { data: entityRows, error: entityError } = await admin.rpc("entities_matching_query", {
            p_user_id: userId,
            p_query: query,
        });
        if (entityError || !Array.isArray(entityRows) || entityRows.length === 0) return [];
        const ids = entityRows.map((r: { entity_id: string }) => r.entity_id);
        const { data, error } = await admin.rpc("match_concepts", {
            query_embedding: embedding,
            match_count: MAX_CONCEPTS_IN_ANSWER,
            p_user_id: userId,
            p_entity_ids: ids,
        });
        if (error) {
            console.warn(`match_concepts failed: ${error.message}`);
            return [];
        }
        return (data ?? []) as ConceptRow[];
    } catch (err) {
        console.warn(`concept stage skipped: ${err}`);
        return [];
    }
}

async function meetingEntities(
    admin: ReturnType<typeof adminClient>,
    userId: string,
    meetingId: string,
): Promise<EntityRow[]> {
    const { data, error } = await admin
        .from("meeting_entities")
        .select("entities!inner(id, name, kind)")
        .eq("meeting_id", meetingId)
        .eq("user_id", userId);
    if (error) {
        console.warn(`meeting entities read failed: ${error.message}`);
        return [];
    }
    return (data ?? [])
        .map((row: { entities: EntityRow | EntityRow[] }) => Array.isArray(row.entities) ? row.entities[0] : row.entities)
        .filter((e): e is EntityRow => Boolean(e?.id && e?.name));
}

async function currentConcepts(
    admin: ReturnType<typeof adminClient>,
    entityIds: string[],
): Promise<Map<string, { claim_key: string; body: string }[]>> {
    const grouped = new Map<string, { claim_key: string; body: string }[]>();
    if (entityIds.length === 0) return grouped;
    const { data, error } = await admin
        .from("concepts")
        .select("entity_id, claim_key, body")
        .in("entity_id", entityIds)
        .eq("state", "current");
    if (error) {
        console.warn(`current concepts read failed: ${error.message}`);
        return grouped;
    }
    for (const row of (data ?? []) as { entity_id: string; claim_key: string; body: string }[]) {
        const list = grouped.get(row.entity_id) ?? [];
        list.push({ claim_key: row.claim_key, body: row.body });
        grouped.set(row.entity_id, list);
    }
    return grouped;
}

async function proposeOps(
    userId: string,
    transcript: NonNullable<Awaited<ReturnType<typeof getTranscript>>>,
    entities: EntityRow[],
    existing: Map<string, { claim_key: string; body: string }[]>,
): Promise<DistillOp[] | null> {
    const known = entities
        .map((e) => {
            const facts = (existing.get(e.id) ?? [])
                .map((c) => `    - ${c.claim_key}: ${c.body}`)
                .join("\n");
            return `- ${e.name} (${e.kind})${facts ? `\n  known:\n${facts}` : ""}`;
        })
        .join("\n");

    const lines = transcript.lines.map((l) => `[${l.idx}] ${l.text}`);
    let body = lines.join("\n");
    if (body.length > MAX_TRANSCRIPT_CHARS) {
        // Middles go first: openings carry who is in the room, ends carry what
        // was decided.
        const half = Math.floor(MAX_TRANSCRIPT_CHARS / 2);
        body = body.slice(0, half) + "\n[…]\n" + body.slice(-half);
    }

    const system = `You distill one finished work session into durable facts about known entities. Restraint is the whole job: most sessions add nothing, and an empty list is the expected answer.

WRITE a claim only when it is ALL of:
- specific — an explicit decision, commitment, number, date, deadline, status change, or stated preference. Not a topic, not a discussion.
- durable — still worth knowing weeks from now, outside this session.
- about one of the KNOWN ENTITIES, by their exact listed name.

NEVER:
- restate the summary, or write what a session merely discussed
- write about an entity not in the list
- rewrite a known claim the session did not change
- invent a date or number the transcript does not state

Each claim:
- "op": "set" — or "retire" when the session says a known claim no longer holds and nothing replaces it
- "entity": the exact listed name
- "kind": "fact" | "decision" | "commitment" | "preference"
- "claim_key": short-kebab-case name for WHICH claim this is ("ship-date", "pricing", "owner"). The same claim uses the same key across sessions — reuse the key of a known claim this changes.
- "body": one standalone sentence naming the entity, in the session's own language, ≤ 300 characters
- "evidence_idx": the [idx] of the transcript line that states it
- "valid_from": ISO date, ONLY when the session states when the fact became true

[OUTPUT] ONLY this JSON, no prose, no code fence:
{"ops": []}`;

    const user = `KNOWN ENTITIES:
${known}

SESSION${transcript.meeting.summary ? ` SUMMARY:\n${transcript.meeting.summary}\n\nTRANSCRIPT` : " TRANSCRIPT"}:
${body}`;

    const content = await completeOnce({
        model: DISTILL_MODEL,
        system,
        user,
        userId,
        task: "distill",
        temperature: 0,
        reasoningOff: true,
    });
    if (content === null) return null;
    try {
        const stripped = content.replace(/^```(?:json)?\s*/i, "").replace(/```\s*$/, "").trim();
        const result = JSON.parse(stripped);
        return Array.isArray(result?.ops) ? result.ops as DistillOp[] : [];
    } catch (err) {
        console.error(`distill parse failed: ${err}`);
        return null;
    }
}

function validFrom(value: unknown): string | null {
    if (typeof value !== "string") return null;
    const t = Date.parse(value);
    // A date the model got wrong is worse than no date: `valid_from` orders
    // supersession. Refuse anything unparsable or in the future.
    if (Number.isNaN(t) || t > Date.now()) return null;
    return new Date(t).toISOString();
}
