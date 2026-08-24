// What a tool call's arguments have to be before an adapter acts on them.
//
// One copy rather than ten. Every adapter had grown its own, and they had begun
// to disagree in a way nothing would have caught: a `closed` argument that
// arrived malformed read as `false` in some and was refused in others, so the
// same tool call meant "reopen it" in one tracker and "that is not valid" in the
// next.
import { ActionError } from "./pipedream.ts";

export function requireString(params: Record<string, unknown>, key: string): string {
    const value = params[key];
    if (typeof value !== "string" || value.trim().length === 0) {
        throw new ActionError("invalid_params", `\`${key}\` is required.`);
    }
    return value.trim();
}

/// A boolean the model may have sent as a string, which providers routinely do.
///
/// Refuses anything else rather than defaulting: the arguments this reads decide
/// whether work is closed or reopened, and guessing at a malformed one is how a
/// tracker ends up disagreeing with the checkbox that drove it.
export function requireBoolean(params: Record<string, unknown>, key: string): boolean {
    const value = params[key];
    if (typeof value === "boolean") return value;
    if (value === "true") return true;
    if (value === "false") return false;
    throw new ActionError("invalid_params", `\`${key}\` must be true or false.`);
}

/// A comma-separated list, bounded.
///
/// The bound is required rather than optional: each of these becomes at least
/// one request to a provider, and an adapter that forgot to cap it fanned out as
/// wide as the model felt like asking.
export function requireList(params: Record<string, unknown>, key: string, max: number): string[] {
    const items = requireString(params, key)
        .split(",")
        .map((item) => item.trim())
        .filter(Boolean);

    if (items.length === 0) {
        throw new ActionError("invalid_params", `\`${key}\` is required.`);
    }
    if (items.length > max) {
        throw new ActionError("invalid_params", `At most ${max} per call.`);
    }
    return items;
}
