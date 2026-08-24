// directory-sync — re-read a connected workspace's member list on request.
//
// Connecting a tool imports its roster once (`integration-reconcile`), which is what
// makes a company usable the minute it is set up. This is the same import, asked
// for again: somebody joined the workspace last week, or the connection was made
// before the organization existed, and nobody should have to disconnect and
// reconnect to pick that up.
//
// Request:  POST { "provider": "linear" }
// Response: { "seen": 42, "linked": 38 } or { "error": { code, message } }
import { json } from "../_shared/http.ts";
import { adminClient, authenticate } from "../_shared/supabase.ts";
import { ActionError, resolveConnection } from "../_shared/integrations/pipedream.ts";
import { apiBase } from "../_shared/integrations/registry.ts";
import { directoryTargetOrg, importDirectory, isDirectorySource } from "../_shared/integrations/directory.ts";

Deno.serve(async (req) => {
    if (req.method !== "POST") {
        return json({ error: "Method not allowed" }, 405);
    }

    const auth = await authenticate(req);
    if (auth instanceof Response) return auth;
    const { user } = auth;

    const body = await req.json().catch(() => null);
    const provider = body?.provider;
    if (typeof provider !== "string" || !isDirectorySource(provider)) {
        return json({ error: { code: "unknown_provider", message: "That tool has no member list." } }, 400);
    }

    const admin = adminClient();
    // The same guard the automatic import uses, for the same reason: filling an
    // organization's directory is an administrative act, and a member's own
    // workspace is not the company.
    const orgId = await directoryTargetOrg(admin, user.id);
    if (!orgId) {
        return json({
            error: {
                code: "not_permitted",
                message: "Only an administrator of your organization can import a directory.",
            },
        }, 200);
    }

    try {
        const connection = await resolveConnection(user.id, provider, apiBase(provider) ?? "");
        const outcome = await importDirectory(admin, connection, orgId);
        return json(outcome, 200);
    } catch (error) {
        if (error instanceof ActionError) {
            console.warn(`directory-sync ${provider}: ${error.code}`);
            return json({ error: { code: error.code, message: error.message } }, 200);
        }
        console.error(`directory-sync ${provider} crashed: ${error}`);
        return json({ error: { code: "internal", message: "Could not read that member list." } }, 500);
    }
});
