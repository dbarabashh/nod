export interface ProviderFailure {
    error: string;
    retryable: boolean;
}

export async function providerFailure(operation: string, response: Response): Promise<ProviderFailure> {
    const detail = (await response.text()).slice(0, 500);
    return {
        error: `${operation} status=${response.status} body=${detail}`,
        // Only rate limiting and provider-side faults are worth retrying; a 4xx
        // is our payload being wrong, and retrying it just burns quota.
        retryable: response.status === 429 || response.status >= 500,
    };
}

// An allowlist, not a filter: the payload is assembled in SQL and may carry
// internal ids for our own bookkeeping. Only these keys are ever handed to the
// provider, so a new column can't quietly become an email variable.
const ALLOWED_TEMPLATE_VARIABLES = new Set([
    "FIRST_NAME",
    "first_name",
    "APP_URL",
    "DOWNLOAD_URL",
    "CALENDLY_URL",
    "calendly_url",
    "PREFERENCE_URL",
    "REWARD_LABEL",
    "EXPIRES_AT",
    "NEXT_BILLING_DATE",
]);

export function templateVariables(payload: unknown): Record<string, string | number> {
    if (!isObject(payload)) return {};
    return Object.fromEntries(
        Object.entries(payload).flatMap(([key, value]) => {
            if (!ALLOWED_TEMPLATE_VARIABLES.has(key)) return [];
            if (typeof value !== "string" && typeof value !== "number") return [];
            return [[key, value]];
        }),
    );
}

// Every optional email must offer a way out that works without logging in.
// Deliverability depends on it as much as the law does.
export function unsubscribeHeaders(payload: unknown): Record<string, string> {
    if (!isObject(payload)) return {};
    const url = payload.PREFERENCE_URL;
    if (typeof url !== "string" || !url.startsWith("https://")) return {};
    return { "List-Unsubscribe": `<${url}>` };
}

export function isObject(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function stringValue(value: unknown): string {
    return typeof value === "string" ? value : "";
}
