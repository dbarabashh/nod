// email-preferences — the API behind `hellonod.app/email-preferences`.
//
// The link in an email carries an opaque 64-hex token in the URL FRAGMENT, so it
// never reaches a server log, a referrer header, or browser history once the page
// strips it. The caller therefore has no session, which is why this function
// runs with verify_jwt = false and treats the token as the whole credential.
//
// Loading the page performs a READ only. A preference changes solely on an
// explicit `update` request, because a mail client that prefetches links must
// never silently alter someone's consent.

import { isObject, stringValue } from "../_shared/email-delivery.ts";
import { json } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";

const ALLOWED_ORIGINS = new Set([
    "https://hellonod.app",
    "https://www.hellonod.app",
    "http://localhost:5173",
    "http://127.0.0.1:5173",
    "http://localhost:3000",
    "http://127.0.0.1:3000",
]);

Deno.serve(async (request: Request): Promise<Response> => {
    const origin = request.headers.get("Origin") ?? "";
    const cors = corsHeaders(origin);
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    if (request.method !== "POST") return json({ error: "Method Not Allowed" }, 405, cors);
    if (!ALLOWED_ORIGINS.has(origin)) return json({ error: "Origin not allowed" }, 403, cors);

    let body: Record<string, unknown>;
    try {
        const parsed = await request.json();
        if (!isObject(parsed)) throw new Error("invalid body");
        body = parsed;
    } catch {
        return json({ error: "Invalid JSON body" }, 400, cors);
    }

    const action = stringValue(body.action);
    const token = stringValue(body.token);
    if ((action !== "read" && action !== "update") || !/^[0-9a-f]{64}$/.test(token)) {
        return json({ error: "Invalid preference request" }, 400, cors);
    }

    const admin = adminClient();
    const { data: userId, error: tokenError } = await admin.rpc("resolve_email_preference_token", { p_token: token });
    if (tokenError) {
        console.error(`email preference token resolution failed: ${tokenError.message}`);
        return json({ error: "Preference service unavailable" }, 500, cors);
    }
    if (typeof userId !== "string") {
        // 410: the link is gone rather than wrong, which is what an expired
        // token actually means to the person holding it.
        return json({ error: "Link expired or invalid" }, 410, cors);
    }

    if (action === "read") {
        const { data, error } = await admin.rpc("public_email_preferences", { p_user_id: userId });
        if (error) {
            console.error(`public_email_preferences failed: ${error.message}`);
            return json({ error: "Preference service unavailable" }, 500, cors);
        }
        return json(data, 200, cors);
    }

    if (!isObject(body.preferences)) return json({ error: "Invalid preferences" }, 400, cors);
    const { data, error } = await admin.rpc("set_public_email_preferences", {
        p_user_id: userId,
        p_preferences: body.preferences,
    });
    if (error) {
        console.warn(`set_public_email_preferences rejected: ${error.message}`);
        return json({ error: "Invalid preferences" }, 400, cors);
    }
    return json(data, 200, cors);
});

function corsHeaders(origin: string): Record<string, string> {
    return {
        "Access-Control-Allow-Origin": ALLOWED_ORIGINS.has(origin) ? origin : "https://hellonod.app",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "content-type",
        "Cache-Control": "no-store",
        "Referrer-Policy": "no-referrer",
        "Vary": "Origin",
    };
}
