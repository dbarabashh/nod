// send-beat-push — tells a phone that one of its beats has been answered.
//
// Called by the `beat_runs_notify_answered` trigger through pg_net, authenticated
// with the shared `INTERNAL_JOB_SECRET` bearer. Never called by the app: a client
// asking us to push to an arbitrary user is a client asking to spam somebody.
//
// The notification carries the beat's NAME and nothing from the report. A lock
// screen is the one place "only you can read it" stops being true, and
// `docs/policies/privacy.md` says that without an asterisk. What it does carry is
// a deep link, so the tap lands on the report the notification is about rather
// than on whatever happens to be newest by the time the app opens.
//
// Tokens that APNs rejects as gone are deleted here. A dead token is retried on
// every beat forever otherwise, and APNs treats that as abuse.
import { isObject, json } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";
import { base64URL } from "../_shared/crypto.ts";

const INTERNAL_JOB_SECRET = Deno.env.get("INTERNAL_JOB_SECRET");
// The .p8 contents, including the BEGIN/END lines. Base64 of the file is also
// accepted, because pasting a multi-line secret into a shell is where this
// usually goes wrong.
const APNS_KEY = Deno.env.get("APNS_KEY_P8");
const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID");
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID");

const GATEWAY = {
    sandbox: "https://api.sandbox.push.apple.com",
    production: "https://api.push.apple.com",
} as const;

// APNs allows a provider token for an hour and rejects one older than that.
// Cached across invocations of a warm instance; a cold start just mints another.
const TOKEN_TTL_MS = 45 * 60 * 1000;
let cachedToken: { value: string; mintedAt: number } | null = null;

interface TokenRow {
    token: string;
    environment: keyof typeof GATEWAY;
    bundle_id: string;
    device_id: string;
}

Deno.serve(async (request: Request): Promise<Response> => {
    if (!INTERNAL_JOB_SECRET) {
        console.error("send-beat-push missing env: INTERNAL_JOB_SECRET");
        return json({ error: "Server misconfigured" }, 500);
    }
    if (request.headers.get("Authorization") !== `Bearer ${INTERNAL_JOB_SECRET}`) {
        return json({ error: "Unauthenticated" }, 401);
    }
    if (!APNS_KEY || !APNS_KEY_ID || !APNS_TEAM_ID) {
        // Not an error worth retrying: the operator has not configured this
        // branch. Answered as OK so pg_net does not record a failure per beat.
        console.warn("send-beat-push: APNs is not configured on this branch");
        return json({ sent: 0, skipped: "apns-unconfigured" }, 200);
    }

    let body: unknown;
    try {
        body = await request.json();
    } catch {
        return json({ error: "Malformed body" }, 400);
    }
    if (!isObject(body)) return json({ error: "Malformed body" }, 400);

    const userID = typeof body.user_id === "string" ? body.user_id : null;
    const beatID = typeof body.beat_id === "string" ? body.beat_id : null;
    const runID = typeof body.run_id === "string" ? body.run_id : null;
    const title = typeof body.title === "string" && body.title.trim() !== "" ? body.title.trim() : "Beat";
    if (!userID || !beatID) return json({ error: "user_id and beat_id are required" }, 400);

    const admin = adminClient();
    const { data, error } = await admin
        .from("push_tokens")
        .select("token, environment, bundle_id, device_id")
        .eq("user_id", userID)
        .eq("platform", "ios");
    if (error) {
        console.error(`send-beat-push could not read tokens: ${error.message}`);
        return json({ error: "Lookup failed" }, 500);
    }

    const tokens = (data ?? []) as TokenRow[];
    if (tokens.length === 0) return json({ sent: 0 }, 200);

    const providerToken = await providerJWT();
    // One link for every device, and the same shape `onOpenURL` already parses,
    // so a notification can be rehearsed with `xcrun simctl openurl`.
    const link = `nod://beat/${beatID}${runID ? `?run=${runID}` : ""}`;
    const payload = JSON.stringify({
        aps: {
            alert: { title, body: "Your report is ready." },
            sound: "default",
            "thread-id": beatID,
        },
        link,
        beat_id: beatID,
        run_id: runID,
    });

    let sent = 0;
    const dead: string[] = [];
    await Promise.all(tokens.map(async (row) => {
        const gateway = GATEWAY[row.environment] ?? GATEWAY.production;
        const response = await fetch(`${gateway}/3/device/${row.token}`, {
            method: "POST",
            headers: {
                "authorization": `bearer ${providerToken}`,
                "apns-topic": row.bundle_id,
                "apns-push-type": "alert",
                // Delivered now: the report is what the person asked to be told
                // about, and holding it for a power window makes it stale news.
                "apns-priority": "10",
                // A second delivery of the same run is the same notification,
                // not another one — a beat re-finished after a retry must not
                // stack on the lock screen.
                "apns-collapse-id": (runID ?? beatID).slice(0, 63),
                "content-type": "application/json",
            },
            body: payload,
        });
        if (response.ok) {
            sent += 1;
            return;
        }
        const reason = await response.text().catch(() => "");
        // 410 is APNs saying the app is gone from that device; BadDeviceToken on
        // a 400 is a token for the other gateway or plain malformed. Both are
        // permanent, and retrying them forever is what gets a sender throttled.
        if (response.status === 410 || reason.includes("BadDeviceToken") || reason.includes("Unregistered")) {
            dead.push(row.device_id);
        } else {
            console.error(`APNs ${response.status} for device ${row.device_id}: ${reason}`);
        }
    }));

    if (dead.length > 0) {
        const { error: pruneError } = await admin
            .from("push_tokens")
            .delete()
            .eq("user_id", userID)
            .in("device_id", dead);
        if (pruneError) console.error(`send-beat-push could not prune tokens: ${pruneError.message}`);
    }

    return json({ sent, pruned: dead.length }, 200);
});

// The ES256 provider token APNs authenticates with. Signed with the .p8 key,
// which is an EC P-256 private key in PKCS#8 — WebCrypto imports it directly, so
// there is no JWT library here to keep current.
async function providerJWT(): Promise<string> {
    const now = Date.now();
    if (cachedToken && now - cachedToken.mintedAt < TOKEN_TTL_MS) return cachedToken.value;

    const header = base64URL(JSON.stringify({ alg: "ES256", kid: APNS_KEY_ID }));
    const claims = base64URL(JSON.stringify({ iss: APNS_TEAM_ID, iat: Math.floor(now / 1000) }));
    const signingInput = `${header}.${claims}`;

    const key = await crypto.subtle.importKey(
        "pkcs8",
        pkcs8Bytes(APNS_KEY!),
        { name: "ECDSA", namedCurve: "P-256" },
        false,
        ["sign"],
    );
    const signature = await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" },
        key,
        new TextEncoder().encode(signingInput),
    );
    const token = `${signingInput}.${base64URL(new Uint8Array(signature))}`;
    cachedToken = { value: token, mintedAt: now };
    return token;
}

// The DER bytes inside a PEM. Accepts the .p8 as Apple hands it over, and also
// the whole file base64-encoded, which is how it usually survives being pasted
// into a secret store that dislikes newlines.
function pkcs8Bytes(key: string): Uint8Array<ArrayBuffer> {
    const text = key.includes("BEGIN PRIVATE KEY") ? key : atob(key.trim());
    const body = text
        .replace(/-----BEGIN PRIVATE KEY-----/, "")
        .replace(/-----END PRIVATE KEY-----/, "")
        .replace(/\s+/g, "");
    const binary = atob(body);
    // Backed by a plain `ArrayBuffer` on purpose: `new Uint8Array(length)` is
    // typed over `ArrayBufferLike`, which `crypto.subtle.importKey` will not
    // accept because it could be shared memory.
    const bytes = new Uint8Array(new ArrayBuffer(binary.length));
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
    return bytes;
}
