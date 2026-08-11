// Resend signs webhooks with Svix: HMAC-SHA256 over `<id>.<timestamp>.<body>`,
// keyed by the base64 part of `whsec_…`. Verified over the RAW body, because
// re-serialising parsed JSON changes the bytes and breaks the signature.

const MAX_AGE_SECONDS = 300;

export async function verifySvix(
    payload: string,
    eventId: string,
    timestamp: string,
    signatureHeader: string,
    secret: string,
    nowMilliseconds = Date.now(),
): Promise<boolean> {
    const timestampSeconds = Number(timestamp);
    // Replay guard: a captured delivery must not be accepted days later even
    // with a valid signature.
    if (
        !eventId || !Number.isFinite(timestampSeconds) ||
        Math.abs(nowMilliseconds / 1000 - timestampSeconds) > MAX_AGE_SECONDS
    ) return false;

    const encodedSecret = secret.startsWith("whsec_") ? secret.slice(6) : secret;
    let secretBytes: Uint8Array;
    try {
        secretBytes = Uint8Array.from(atob(encodedSecret), (character) => character.charCodeAt(0));
    } catch {
        return false;
    }
    const secretBuffer = new ArrayBuffer(secretBytes.byteLength);
    new Uint8Array(secretBuffer).set(secretBytes);
    const key = await crypto.subtle.importKey(
        "raw",
        secretBuffer,
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["sign"],
    );
    const digest = new Uint8Array(
        await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${eventId}.${timestamp}.${payload}`)),
    );

    // The header can carry several space-separated signatures during a secret
    // rotation; any match is enough.
    return signatureHeader.split(" ").some((entry) => {
        const [version, encoded] = entry.split(",", 2);
        if (version !== "v1" || !encoded) return false;
        try {
            const candidate = Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0));
            return timingSafeEqual(digest, candidate);
        } catch {
            return false;
        }
    });
}

function timingSafeEqual(left: Uint8Array, right: Uint8Array): boolean {
    if (left.length !== right.length) return false;
    let difference = 0;
    for (let index = 0; index < left.length; index += 1) {
        difference |= left[index] ^ right[index];
    }
    return difference === 0;
}
