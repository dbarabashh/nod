import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { sha256Hex } from "./crypto.ts";

// deno-lint-ignore no-explicit-any
const edgeWaitUntil = (p: PromiseLike<unknown>) => (globalThis as any).EdgeRuntime?.waitUntil?.(Promise.resolve(p));

// Shared auth gate for both transports (`connect`, `mcp`): resolve a personal
// token to its owner's user_id, or null if the token is empty, unknown, or
// revoked. The last_used_at stamp is handed to EdgeRuntime.waitUntil so the
// isolate doesn't drop it when the response returns first.
export async function resolveConnectionUser(admin: SupabaseClient, token: string): Promise<string | null> {
    const trimmed = token.trim();
    if (!trimmed) return null;

    const { data, error } = await admin
        .from("connections")
        .select("id, user_id")
        .eq("token_hash", await sha256Hex(trimmed))
        .is("revoked_at", null)
        .maybeSingle();

    if (error) {
        console.error(`connection lookup failed: ${error.message}`);
        return null;
    }
    if (!data) return null;

    edgeWaitUntil(
        admin
            .from("connections")
            .update({ last_used_at: new Date().toISOString() })
            .eq("id", data.id)
            .then(undefined, (e: unknown) => console.warn(`last_used_at stamp failed: ${e}`)),
    );

    return data.user_id as string;
}
