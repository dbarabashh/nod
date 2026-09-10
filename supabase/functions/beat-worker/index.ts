// beat-worker — answers the beats nobody's Mac was awake to claim.
//
// Woken by pg_cron through `invoke_internal_edge_job`, authenticated with
// `INTERNAL_JOB_SECRET` — there is no user session here. The Mac keeps right
// of first refusal: `claim_stale_beat_runs` only hands over runs still `due`
// three minutes past their moment, and the claim itself is the same mutex the
// desktop has always taken, so the two runners cannot answer one question
// twice.
//
// The answer is a reduced grounded turn — concepts for the entities the
// question names, then transcript chunks — written into an ordinary thread
// exactly where the Mac would have written it. Marking the run `done` fires
// the existing push trigger; this function never talks to APNs itself.
import { modelFor } from "../_shared/models.ts";
import { adminClient } from "../_shared/supabase.ts";
import { json } from "../_shared/http.ts";
import { completeOnce } from "../_shared/complete.ts";
import { embedText } from "../_shared/search.ts";
import { conceptsForSearch } from "../_shared/knowledge.ts";

const INTERNAL_JOB_SECRET = Deno.env.get("INTERNAL_JOB_SECRET");

// The same default a stock client's chat runs on, overridable per branch the
// same way every other task model is.
const BEAT_MODEL = modelFor("beat");

// Matches the client's grounding floor: below this a chunk is a coincidence.
const MIN_SIMILARITY = 0.3;
const MATCH_COUNT = 8;

interface StaleRun {
    run_id: string;
    beat_id: string;
    user_id: string;
    prompt: string;
    title: string;
    scheduled_for: string;
}

Deno.serve(async (req) => {
    if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
    if (!INTERNAL_JOB_SECRET) {
        console.error("missing env: INTERNAL_JOB_SECRET");
        return json({ error: "not configured" }, 500);
    }
    if (req.headers.get("Authorization") !== `Bearer ${INTERNAL_JOB_SECRET}`) {
        return json({ error: "unauthorized" }, 401);
    }

    const admin = adminClient();
    const { data, error } = await admin.rpc("claim_stale_beat_runs", { p_limit: 5 });
    if (error) {
        console.error(`claim failed: ${error.message}`);
        return json({ answered: 0, error: error.message }, 500);
    }
    const runs = (data ?? []) as StaleRun[];
    let answered = 0;
    // Serially, oldest first — the same discipline the Mac runner keeps, for
    // the same reason: each answer is a full model turn.
    for (const run of runs) {
        try {
            if (await answer(admin, run)) answered += 1;
        } catch (err) {
            console.error(`beat run ${run.run_id} crashed: ${err}`);
            await fail(admin, run.run_id, "The server could not write this report.");
        }
    }
    if (runs.length > 0) console.log(`beat-worker claimed=${runs.length} answered=${answered}`);
    return json({ claimed: runs.length, answered }, 200);
});

async function answer(admin: ReturnType<typeof adminClient>, run: StaleRun): Promise<boolean> {
    // The entitlement read and the embedding depend on nothing but the run, so
    // they start together; the same overlap the proxy's own search path keeps.
    const entitled = admin.rpc("resolve_entitlement", { p_user_id: run.user_id });
    const embedded = embedText(run.prompt).catch((err) => {
        console.error(`embed failed for run ${run.run_id}: ${err}`);
        return null;
    });

    // The same entitlement the question needs when typed. A lapsed plan gets
    // an honest failed run, not a silent hole where a briefing should be.
    const { data: ent } = await entitled;
    const status = typeof ent?.status === "string" ? ent.status : "";
    const features = Array.isArray(ent?.features) ? ent.features : [];
    if (!["active", "trialing"].includes(status) || !features.includes("ask_across_meetings")) {
        await fail(admin, run.run_id, "Your plan no longer includes questions across sessions.");
        return false;
    }

    const embedding = await embedded;
    if (embedding === null) {
        await fail(admin, run.run_id, "Retrieval was unavailable.");
        return false;
    }

    const [concepts, { data: chunkRows, error: matchError }] = await Promise.all([
        conceptsForSearch(admin, run.user_id, run.prompt, embedding),
        admin.rpc("match_session_chunks", {
            query_embedding: embedding,
            match_count: MATCH_COUNT,
            p_user_id: run.user_id,
        }),
    ]);
    if (matchError) console.warn(`chunk match failed: ${matchError.message}`);
    const chunks = ((chunkRows ?? []) as { meeting_id: string; content: string; similarity: number }[])
        .filter((c) => c.similarity >= MIN_SIMILARITY);

    const meetingIds = [...new Set([
        ...chunks.map((c) => c.meeting_id),
        ...concepts.map((c) => c.meeting_id).filter((id): id is string => Boolean(id)),
    ])];
    const titles = await meetingTitles(admin, meetingIds);

    const content = await compose(run, concepts, chunks, titles);
    if (content === null) {
        await fail(admin, run.run_id, "The report could not be written.");
        return false;
    }

    // The thread first, then both turns, then the run — the push fires off the
    // run update, so everything it links to exists before any phone hears.
    const { data: thread, error: threadError } = await admin
        .from("knowledge_threads")
        .insert({ user_id: run.user_id, title: run.title, beat_id: run.beat_id })
        .select("id")
        .single();
    if (threadError || !thread) {
        await fail(admin, run.run_id, "The answer could not be saved.");
        return false;
    }
    const sources = meetingIds
        .map((id) => titles.get(id) ? { id, title: titles.get(id) } : null)
        .filter(Boolean);
    // One shape for both rows: PostgREST refuses a batch whose objects carry
    // different key sets.
    const { error: messageError } = await admin.from("knowledge_messages").insert([
        { thread_id: thread.id, user_id: run.user_id, role: "user", content: run.prompt, sources: [] },
        { thread_id: thread.id, user_id: run.user_id, role: "assistant", content, sources },
    ]);
    if (messageError) {
        console.error(`messages insert failed: ${messageError.message}`);
        await fail(admin, run.run_id, "The answer could not be saved.");
        return false;
    }

    const { error: doneError } = await admin
        .from("beat_runs")
        .update({ status: "done", thread_id: thread.id, finished_at: new Date().toISOString() })
        .eq("id", run.run_id);
    if (doneError) {
        console.error(`run finish failed: ${doneError.message}`);
        return false;
    }
    return true;
}

async function meetingTitles(
    admin: ReturnType<typeof adminClient>,
    ids: string[],
): Promise<Map<string, string>> {
    const table = new Map<string, string>();
    if (ids.length === 0) return table;
    const { data } = await admin
        .from("meetings")
        .select("id, title, started_at")
        .in("id", ids);
    for (const row of (data ?? []) as { id: string; title: string | null; started_at: string | null }[]) {
        const day = row.started_at ? new Date(row.started_at).toISOString().slice(0, 10) : "";
        table.set(row.id, `${row.title ?? "Untitled session"}${day ? ` — ${day}` : ""}`);
    }
    return table;
}

async function compose(
    run: StaleRun,
    concepts: Awaited<ReturnType<typeof conceptsForSearch>>,
    chunks: { meeting_id: string; content: string; similarity: number }[],
    titles: Map<string, string>,
): Promise<string | null> {
    // The grounding shape mirrors the client's: `KnowledgeChatStore` builds
    // the same ESTABLISHED block and `[From: …]` excerpts for typed questions.
    // Change one and change the other.
    const established = concepts.length === 0 ? "" : "\n\n[ESTABLISHED — distilled facts; cite the date when one is given]\n"
        + concepts.map((c) => `- [${c.kind}]${c.valid_from ? ` (since ${c.valid_from.slice(0, 10)})` : ""} ${c.body}`).join("\n");
    const excerpts = chunks.length === 0 ? "(no relevant excerpts were found)" : chunks
        .map((c) => `[From: ${titles.get(c.meeting_id) ?? "a past session"}]\n${c.content}`)
        .join("\n\n---\n\n");

    const system = `You are Nod, writing a scheduled report the user will read on their own, hours from now — nobody is in a conversation with you. Ground everything in the excerpts and established facts below; when they do not answer the question, say what is missing rather than inventing. Prefer the newest dated material when sessions disagree, and say the date when a fact carries one. Write in the language of the question. Be complete but not padded. Write "about" rather than "~" for an approximation — a tilde is read as strikethrough where this lands. Never leave a line holding only punctuation: finish the sentence or drop it.${established}

[FROM THE USER'S SESSIONS]
${excerpts}`;

    return await completeOnce({
        model: BEAT_MODEL,
        system,
        user: run.prompt,
        userId: run.user_id,
        task: "beat",
    });
}

async function fail(admin: ReturnType<typeof adminClient>, runId: string, message: string): Promise<void> {
    const { error } = await admin
        .from("beat_runs")
        .update({ status: "failed", error: message, finished_at: new Date().toISOString() })
        .eq("id", runId);
    if (error) console.error(`run fail-mark failed: ${error.message}`);
}
