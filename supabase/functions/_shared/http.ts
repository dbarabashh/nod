// Shared JSON response helper. Extra headers (e.g. CORS) merge over the default
// Content-Type. Used by every function so a cross-cutting change (a request-id
// header, a CORS tweak) lives in one place.
export function json(body: unknown, status: number, headers: Record<string, string> = {}): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json", ...headers },
    });
}
