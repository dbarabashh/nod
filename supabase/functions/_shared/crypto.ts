// Shared hashing for token gates. A connection token is hashed on-device and
// stored as a hex SHA-256; both `connect` and `mcp` resolve a request by hashing
// the presented token and matching `connections.token_hash`.
export async function sha256Hex(input: string): Promise<string> {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
    return Array.from(new Uint8Array(digest))
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");
}

/// Hex HMAC-SHA256 verification for a signed webhook body.
///
/// `paddle-webhook` and `nango-webhook` both need exactly this, and both were
/// about to carry their own copy. Verification goes through `crypto.subtle`
/// rather than a string compare, which is constant-time by construction.
export async function verifyHmacSha256Hex(
    secret: string,
    payload: string,
    signature: string,
): Promise<boolean> {
    const provided = hexToBytes(signature);
    if (!provided) return false;

    const key = await crypto.subtle.importKey(
        "raw",
        new TextEncoder().encode(secret),
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["verify"],
    );
    return crypto.subtle.verify("HMAC", key, provided, new TextEncoder().encode(payload));
}

function hexToBytes(hex: string): Uint8Array<ArrayBuffer> | null {
    if (hex.length === 0 || hex.length % 2 !== 0 || !/^[0-9a-f]+$/i.test(hex)) return null;
    const bytes = new Uint8Array(new ArrayBuffer(hex.length / 2));
    for (let i = 0; i < bytes.length; i++) {
        bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    }
    return bytes;
}
