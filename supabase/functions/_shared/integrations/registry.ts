// The provider table. Adding an integration is one import and one entry here —
// nothing in `integration-action` knows a provider name.
import type { Connection } from "./nango.ts";
import { GOOGLE_CALENDAR_ACTIONS } from "./googleCalendar.ts";
import { LINEAR_ACTIONS } from "./linear.ts";

export type ActionHandler = (
    connection: Connection,
    params: Record<string, unknown>,
) => Promise<unknown>;

export type ActionHandlers = Record<string, ActionHandler>;

// One list, mirroring `integration_connections`'s `provider` check. `null` means
// a provider that can be connected but never acted in — the shape is kept for
// the next such provider, and because `hasActions` is what stops a connection
// being addressed as though it took commands.
//
// The calendar reads on a schedule with the service role and writes only here,
// through one action a person confirmed on their own screen.
const PROVIDERS: Record<string, ActionHandlers | null> = {
    "linear": LINEAR_ACTIONS,
    "google-calendar": GOOGLE_CALENDAR_ACTIONS,
};

export function handlerFor(provider: string, action: string): ActionHandler | undefined {
    return PROVIDERS[provider]?.[action];
}

export function isConnectableProvider(provider: string): boolean {
    return Object.hasOwn(PROVIDERS, provider);
}

/// `integration-action` asks this rather than `isConnectableProvider`, so a
/// provider that only ever gets read cannot be addressed as though it took
/// commands.
export function hasActions(provider: string): boolean {
    return PROVIDERS[provider] != null;
}
