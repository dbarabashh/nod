// proposal-execute — the only way an approved proposal becomes real work.
//
// The client already has `integration-action`, and could call it directly with
// the same parameters. That is exactly why this exists: what a client asks for
// is not a validation, and "the user pressed Approve" is a claim the server has
// to check rather than a fact it can be told. So the proposal is re-read here
// under the caller's own row-level security, its state is claimed atomically,
// the person it names is resolved server-side, and only then does anything
// reach a provider.
//
// Request:  POST { "proposal_id": "…" }
// Response: { "result": { key, title, url } } or { "error": { code, message } }
//
// Errors come back 200 with an `error` body when the user can do something
// about them — not connected, no such Linear team — matching what
// `integration-action` already does, and the proposal is left `failed` with the
// same message so the card can say why without a second round trip.
import { json } from "../_shared/http.ts";
import { adminClient, authenticate } from "../_shared/supabase.ts";
import { ActionError, resolveConnection } from "../_shared/integrations/pipedream.ts";
import { assertProviderPermitted } from "../_shared/integrations/policy.ts";
import { apiBase, handlerFor } from "../_shared/integrations/registry.ts";
import { type Proposal, resolveAssignee } from "./assignee.ts";
import { type FiledRow, filedReference } from "./filed.ts";
import { isProposable } from "../_shared/integrations/metering.ts";

/// Parameters that describe *who* rather than *what*, stripped before the call.
/// A provider has no use for a `people.id`, and `assignee_name` is the copy the
/// review card renders.
const INTERNAL_PARAMS = ["assignee_person_id", "assignee_name", "assignee_hint"];

Deno.serve(async (req) => {
    if (req.method !== "POST") {
        return json({ error: "Method not allowed" }, 405);
    }

    const auth = await authenticate(req);
    if (auth instanceof Response) return auth;
    const { user } = auth;

    const body = await req.json().catch(() => null);
    const proposalId = body?.proposal_id;
    if (typeof proposalId !== "string") {
        return json({ error: { code: "invalid_params", message: "`proposal_id` is required." } }, 400);
    }

    const admin = adminClient();

    // Ownership is a row filter, not a trust decision: the proposal must belong
    // to the caller, and `user_id` is the same column the RLS policy uses.
    const { data: proposal, error: readError } = await admin
        .from("action_proposals")
        .select("id, org_id, action_item_id, type, status, parameters")
        .eq("id", proposalId)
        .eq("user_id", user.id)
        .maybeSingle<Proposal>();

    if (readError) {
        console.error(`proposal read failed: ${readError.message}`);
        return json({ error: { code: "internal", message: "Could not read that proposal." } }, 500);
    }
    if (!proposal) {
        return json({ error: { code: "not_found", message: "No such proposal." } }, 404);
    }
    if (proposal.status !== "approved") {
        // Includes `executing` and `completed`, which is the case that matters:
        // a double-tap must not file two issues.
        return json({
            error: { code: "not_approved", message: `That proposal is ${proposal.status}.` },
        }, 200);
    }

    const [providerName, action] = proposal.type.split(".", 2);
    const handler = providerName && action ? handlerFor(providerName, action) : undefined;
    if (!handler) {
        return json({ error: { code: "unknown_action", message: `Nothing can perform ${proposal.type}.` } }, 400);
    }
    if (!isProposable(action)) {
        // A read through this door would skip the credit pool.
        return json({ error: { code: "not_a_write", message: `${proposal.type} is not something a proposal can do.` } }, 400);
    }

    // The row this offer was made for may have been filed by hand while the
    // offer stood. Then the work is done: the proposal is settled onto that
    // ticket and answers with it, and nothing reaches the provider.
    if (proposal.action_item_id) {
        const { data: row } = await admin
            .from("action_items")
            .select("external_provider, external_key, external_url, deleted_at")
            .eq("id", proposal.action_item_id)
            .eq("user_id", user.id)
            .maybeSingle<FiledRow>();
        if (!row || row.deleted_at) {
            // The row is gone; so is the reason to file it. Rejected rather
            // than failed, so nothing offers to try again.
            await admin
                .from("action_proposals")
                .update({ status: "rejected", decided_at: new Date().toISOString(), decided_by: user.id })
                .eq("id", proposal.id)
                .eq("status", "approved");
            return json({ error: { code: "row_deleted", message: "That task was deleted." } }, 200);
        }
        const filed = filedReference(row);
        if (filed) {
            await admin
                .from("action_proposals")
                .update({
                    status: "completed",
                    executed_at: new Date().toISOString(),
                    resolved_parameters: proposal.parameters,
                    external_provider: filed.provider,
                    external_key: filed.key,
                    external_url: filed.url,
                })
                .eq("id", proposal.id)
                .eq("status", "approved");
            if (proposal.org_id) {
                await admin.from("audit_log").insert({
                    org_id: proposal.org_id,
                    actor_user_id: user.id,
                    action: "proposal.executed",
                    target_type: "action_proposal",
                    target_id: proposal.id,
                    metadata: { type: proposal.type, external_key: filed.key, settled_onto_existing: true },
                });
            }
            console.info(`proposal ${proposal.type} settled onto ${filed.key}, already filed`);
            return json({ result: { key: filed.key, title: null, url: filed.url, provider: filed.provider } }, 200);
        }
    }

    // `resolveConnection` below would refuse this anyway. Asking here as well
    // is for the outcome rather than the gate: this runs before the claim, so a
    // proposal refused by a policy stays `approved` and retryable — the policy
    // may be back tomorrow, and a proposal marked `failed` for a reason outside
    // the person's control reads as work they have to redo.
    try {
        await assertProviderPermitted(user.id, providerName);
    } catch (error) {
        if (!(error instanceof ActionError)) throw error;
        return json({ error: { code: error.code, message: error.message } }, 200);
    }

    // The claim. `eq("status", "approved")` is what makes it a claim rather than
    // a write: two requests racing, only one changes a row, and the loser reads
    // zero rows back and stops.
    const { data: claimed, error: claimError } = await admin
        .from("action_proposals")
        .update({ status: "executing" })
        .eq("id", proposal.id)
        .eq("status", "approved")
        .select("id");

    if (claimError) {
        console.error(`proposal claim failed: ${claimError.message}`);
        return json({ error: { code: "internal", message: "Could not start that action." } }, 500);
    }
    if (!claimed?.length) {
        return json({ error: { code: "already_running", message: "That action is already running." } }, 200);
    }

    try {
        const connection = await resolveConnection(user.id, providerName, apiBase(providerName) ?? "");
        const parameters = { ...proposal.parameters };
        // Resolved here and nowhere else. The client sends a `people.id`; what
        // reaches Linear is a Linear account, and the translation between them
        // is the one step a client must not be able to skip or fake.
        const assignee = await resolveAssignee(admin, connection, proposal);
        for (const key of INTERNAL_PARAMS) delete parameters[key];
        if (assignee) parameters.assigneeId = assignee;

        const result = await handler(connection, parameters as Record<string, unknown>, { userId: user.id }) as {
            key?: string;
            title?: string;
            url?: string;
        };

        await admin
            .from("action_proposals")
            .update({
                status: "completed",
                executed_at: new Date().toISOString(),
                resolved_parameters: parameters,
                external_provider: providerName,
                external_key: result.key ?? null,
                external_url: result.url ?? null,
            })
            .eq("id", proposal.id);

        // The checklist row this came from now points at the ticket, exactly as
        // it would had the user filed it by hand. Without this the same task
        // would still offer its filing mark, and pressing it would make a
        // second issue.
        if (proposal.action_item_id && result.key && result.url) {
            await admin
                .from("action_items")
                .update({
                    external_provider: providerName,
                    external_key: result.key,
                    external_url: result.url,
                    external_created_at: new Date().toISOString(),
                })
                .eq("id", proposal.action_item_id)
                .eq("user_id", user.id)
                .is("external_provider", null);
        }

        if (proposal.org_id) {
            await admin.from("audit_log").insert({
                org_id: proposal.org_id,
                actor_user_id: user.id,
                action: "proposal.executed",
                target_type: "action_proposal",
                target_id: proposal.id,
                metadata: { type: proposal.type, external_key: result.key ?? null },
            });
        }

        console.info(`proposal executed ${proposal.type}`);
        return json({ result }, 200);
    } catch (error) {
        const failure = error instanceof ActionError
            ? { code: error.code, message: error.message }
            : { code: "internal", message: "The action failed." };

        await admin
            .from("action_proposals")
            .update({
                status: "failed",
                failure_code: failure.code,
                failure_message: failure.message,
            })
            .eq("id", proposal.id);

        if (proposal.org_id) {
            await admin.from("audit_log").insert({
                org_id: proposal.org_id,
                actor_user_id: user.id,
                action: "proposal.failed",
                target_type: "action_proposal",
                target_id: proposal.id,
                metadata: { type: proposal.type, code: failure.code },
            });
        }

        if (error instanceof ActionError) {
            console.warn(`proposal ${proposal.type} failed: ${error.code}`);
            return json({ error: failure }, 200);
        }
        console.error(`proposal ${proposal.type} crashed: ${error}`);
        return json({ error: failure }, 500);
    }
});
