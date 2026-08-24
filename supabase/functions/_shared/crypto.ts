// Shared hashing for token gates. A connection token is hashed on-device and
// stored as a hex SHA-256; both `connect` and `mcp` resolve a request by hashing
// the presented token and matching `connections.token_hash`.
export async function sha256Hex(input: string): Promise<string> {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
    return Array.from(new Uint8Array(digest))
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");
}
