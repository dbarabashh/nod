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
import { apiBase, handlerFor } from "../_shared/integrations/registry.ts";
import { resolveAssignee } from "./assignee.ts";

interface Proposal {
    id: string;
    org_id: string | null;
    action_item_id: string | null;
    type: string;
    status: string;
    parameters: Record<string, unknown>;
}

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

    // Checked again here, having already been checked at approval: an
    // organization can withdraw a tool between saying yes and this running, and
    // the moment that matters is the one where something leaves Nod.
    if (proposal.org_id) {
        const { data: allowed } = await admin.rpc("org_allows_provider", {
            p_org: proposal.org_id,
            p_provider: providerName,
        });
        if (allowed === false) {
            return json({
                error: {
                    code: "not_permitted",
                    message: `Your organization does not allow Nod to act in ${providerName}.`,
                },
            }, 200);
        }
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
