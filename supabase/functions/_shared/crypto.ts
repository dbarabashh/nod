// Shared hashing for token gates. A connection token is hashed on-device and
// stored as a hex SHA-256; both `connect` and `mcp` resolve a request by hashing
// the presented token and matching `connections.token_hash`.
export async function sha256Hex(input: string): Promise<string> {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
    return Array.from(new Uint8Array(digest))
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");
}

/// Url-safe base64, unpadded. Bytes are chunked so a long input cannot overflow
/// the call stack that spreading them into `String.fromCharCode` uses.
export function base64URL(input: string | Uint8Array): string {
    const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
    let binary = "";
    for (let at = 0; at < bytes.length; at += 0x8000) {
        binary += String.fromCharCode(...bytes.subarray(at, at + 0x8000));
    }
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
