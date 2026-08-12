// The provider table. Adding an integration is one import and one entry here —
// nothing in `integration-action` knows a provider name.
import type { Connection } from "./nango.ts";
import { LINEAR_ACTIONS } from "./linear.ts";

export type ActionHandler = (
    connection: Connection,
    params: Record<string, unknown>,
) => Promise<unknown>;

export type ActionHandlers = Record<string, ActionHandler>;

const PROVIDERS: Record<string, ActionHandlers> = {
    linear: LINEAR_ACTIONS,
};

export function handlerFor(provider: string, action: string): ActionHandler | undefined {
    return Object.hasOwn(PROVIDERS, provider) ? PROVIDERS[provider][action] : undefined;
}

/// Mirrors the `provider` check on `integration_connections`, so a provider that
/// reaches this file but not the migration fails loudly at the door.
export function isKnownProvider(provider: string): boolean {
    return Object.hasOwn(PROVIDERS, provider);
}
