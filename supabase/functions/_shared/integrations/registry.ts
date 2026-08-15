// The provider table. Adding an integration is one import and one entry here —
// nothing in `integration-action` knows a provider name.
import type { Connection } from "./nango.ts";
import { LINEAR_ACTIONS } from "./linear.ts";

export type ActionHandler = (
    connection: Connection,
    params: Record<string, unknown>,
) => Promise<unknown>;

export type ActionHandlers = Record<string, ActionHandler>;

// One list, mirroring `integration_connections`'s `provider` check. `null` means
// a provider that can be connected but never acted in: a calendar is read by the
// sync, on a schedule, with the service role, and is never the target of a tool
// call. Two separate literals let one be edited without the other, and a typo in
// the second would have surfaced only at connect time, in production.
const PROVIDERS: Record<string, ActionHandlers | null> = {
    "linear": LINEAR_ACTIONS,
    "google-calendar": null,
};

export function handlerFor(provider: string, action: string): ActionHandler | undefined {
    return PROVIDERS[provider]?.[action];
}

export function isConnectableProvider(provider: string): boolean {
    return Object.hasOwn(PROVIDERS, provider);
}

/// `integration-action` asks this rather than `isConnectableProvider`, so a
/// connected calendar cannot be addressed as though it took commands.
export function hasActions(provider: string): boolean {
    return PROVIDERS[provider] != null;
}
