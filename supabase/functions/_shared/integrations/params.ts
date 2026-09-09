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

/// The same, for a flag the caller may leave out: undefined when absent, never
/// a guessed default.
export function booleanOf(params: Record<string, unknown>, key: string): boolean | undefined {
    if (params[key] === undefined || params[key] === null) return undefined;
    return requireBoolean(params, key);
}

/// The first of several names an argument may travel under that was actually
/// sent, or the first name when none was — so the refusal names the one the
/// contract prefers.
export function nameOf(params: Record<string, unknown>, ...names: string[]): string {
    return names.find((name) => params[name] !== undefined && params[name] !== null) ?? names[0];
}

/// The refusals a caller may word in its own terms — "people per invitation",
/// "addresses at a time" — so a shared helper does not flatten every adapter's
/// message into one.
export interface ListWording {
    tooMany?: string;
    invalid?: (item: string) => string;
}

/// A list the model may have sent comma-separated or as an array, trimmed.
/// Empty when absent — whether that is allowed is the caller's call. Only the
/// strings of an array are kept: anything else is a shape the model got wrong,
/// and stringifying it would forward "[object Object]" to a provider.
///
/// The bound is required rather than optional: each of these becomes at least
/// one request to a provider, and an adapter that forgot to cap it fanned out as
/// wide as the model felt like asking.
export function listOf(
    params: Record<string, unknown>,
    key: string,
    max: number,
    wording: ListWording = {},
): string[] {
    const raw = params[key];
    const items = typeof raw === "string"
        ? raw.split(",").map((item) => item.trim()).filter(Boolean)
        : Array.isArray(raw)
        ? raw.filter((item): item is string => typeof item === "string").map((item) => item.trim()).filter(Boolean)
        : [];

    if (items.length > max) {
        throw new ActionError("invalid_params", wording.tooMany ?? `At most ${max} per call.`);
    }
    return items;
}

export function requireList(
    params: Record<string, unknown>,
    key: string,
    max: number,
    wording: ListWording = {},
): string[] {
    const items = listOf(params, key, max, wording);
    if (items.length === 0) {
        throw new ActionError("invalid_params", `\`${key}\` is required.`);
    }
    return items;
}

/// Addresses only — no display names, no whitespace of any kind. A tab or a
/// linebreak inside an address would land verbatim in a mail header, which is
/// the same injection a subject line has to guard against.
const EMAIL = /^[^\s@,]+@[^\s@,]+$/;

function checkedEmails(list: string[], wording: ListWording): string[] {
    for (const email of list) {
        if (!EMAIL.test(email)) {
            throw new ActionError(
                "invalid_params",
                wording.invalid?.(email) ?? `"${email}" is not a bare email address.`,
            );
        }
    }
    return list;
}

export function emailsOf(
    params: Record<string, unknown>,
    key: string,
    max: number,
    wording: ListWording = {},
): string[] {
    return checkedEmails(listOf(params, key, max, wording), wording);
}

export function requireEmails(
    params: Record<string, unknown>,
    key: string,
    max: number,
    wording: ListWording = {},
): string[] {
    return checkedEmails(requireList(params, key, max, wording), wording);
}
