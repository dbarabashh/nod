// The provider table. Adding an integration is one import and one entry here —
// nothing in `integration-action` knows a provider name.
import type { Connection } from "./pipedream.ts";
import { ASANA_ACTIONS } from "./asana.ts";
import { GITHUB_ACTIONS } from "./github.ts";
import { GMAIL_ACTIONS } from "./gmail.ts";
import { GOOGLE_DRIVE_ACTIONS } from "./googleDrive.ts";
import { HUBSPOT_ACTIONS } from "./hubspot.ts";
import { GOOGLE_ADS_ACTIONS } from "./googleAds.ts";
import { GOOGLE_CALENDAR_ACTIONS } from "./googleCalendar.ts";
import { GOOGLE_TASKS_ACTIONS } from "./googleTasks.ts";
import { JIRA_ACTIONS } from "./jira.ts";
import { NOTION_ACTIONS } from "./notion.ts";
import { LINEAR_ACTIONS } from "./linear.ts";
import { SLACK_ACTIONS } from "./slack.ts";

/// Who an action is being carried out for.
///
/// Optional because most actions never need it: they hand a request to a
/// provider and hand the answer back. It exists for the ones that also have to
/// write what they just did into our own tables — an event created here has to
/// reach `calendar_events`, and that row is keyed by the person.
export interface ActionContext {
    userId: string;
}

type ActionHandler = (
    connection: Connection,
    params: Record<string, unknown>,
    context?: ActionContext,
) => Promise<unknown>;

export type ActionHandlers = Record<string, ActionHandler>;

// One record per provider: what the broker calls it, which API it speaks, and
// what Nod can do in it. One table rather than three — the broker module and
// this file were keyed on the same string and had to agree, and a provider
// present in one and missing from the other took every reconcile down with it.
//
// `actions: null` means a provider that can be connected but never acted in.
// The calendar reads on a schedule with the service role and writes only through
// actions a person confirmed on their own screen.
interface Provider {
    /// The broker's app slug. `slack` is Connect's legacy app; `slack_v2` is the
    /// current one, which is why this is not simply our own name.
    slug: string;
    /// The provider's own API root. Every adapter path is relative to it.
    base: string;
    actions: ActionHandlers | null;
}

const PROVIDERS: Record<string, Provider> = {
    "linear": {
        slug: "linear",
        base: "https://api.linear.app/",
        actions: LINEAR_ACTIONS,
    },
    "google-calendar": {
        slug: "google_calendar",
        base: "https://www.googleapis.com/",
        actions: GOOGLE_CALENDAR_ACTIONS,
    },
    "github": {
        slug: "github",
        base: "https://api.github.com/",
        actions: GITHUB_ACTIONS,
    },
    "asana": {
        slug: "asana",
        base: "https://app.asana.com/",
        actions: ASANA_ACTIONS,
    },
    "gmail": {
        slug: "gmail",
        base: "https://gmail.googleapis.com/",
        actions: GMAIL_ACTIONS,
    },
    "google-drive": {
        slug: "google_drive",
        base: "https://www.googleapis.com/",
        actions: GOOGLE_DRIVE_ACTIONS,
    },
    "hubspot": {
        slug: "hubspot",
        base: "https://api.hubapi.com/",
        actions: HUBSPOT_ACTIONS,
    },
    "jira": {
        slug: "jira",
        // A 3LO app never addresses a customer's site directly; the adapter
        // rewrites every path onto `api.atlassian.com/ex/jira/{cloudId}`.
        base: "https://api.atlassian.com/",
        actions: JIRA_ACTIONS,
    },
    "notion": {
        slug: "notion",
        base: "https://api.notion.com/",
        actions: NOTION_ACTIONS,
    },
    "google-ads": {
        slug: "google_ads",
        // Not Google's API root. Google Ads refuses a request without a
        // developer token, which is issued to an application and which the
        // broker holds; its proxy adds one and takes the real request nested in
        // the body. See `googleAds.ts`.
        base: "https://googleads.m.pipedream.net/",
        actions: GOOGLE_ADS_ACTIONS,
    },
    "google-tasks": {
        slug: "google_tasks",
        base: "https://tasks.googleapis.com/",
        actions: GOOGLE_TASKS_ACTIONS,
    },
    "slack": {
        slug: "slack_v2",
        base: "https://slack.com/api/",
        actions: SLACK_ACTIONS,
    },
};

export function handlerFor(provider: string, action: string): ActionHandler | undefined {
    return PROVIDERS[provider]?.actions?.[action];
}

export function isConnectableProvider(provider: string): boolean {
    return Object.hasOwn(PROVIDERS, provider);
}

/// `integration-action` asks this rather than `isConnectableProvider`, so a
/// provider that only ever gets read cannot be addressed as though it took
/// commands.
export function hasActions(provider: string): boolean {
    return PROVIDERS[provider]?.actions != null;
}

/// Which API a provider speaks. Handed to `proxy` by the caller that already
/// knows the provider, so the broker module needs no table of its own.
export function apiBase(provider: string): string | undefined {
    return PROVIDERS[provider]?.base;
}

export function appSlug(provider: string): string | undefined {
    return PROVIDERS[provider]?.slug;
}

/// Our provider name for a broker app slug, or undefined for an app somebody
/// connected that we have no adapter for. Reconciliation asks this rather than
/// trusting the slug, so an account for an app we never offered cannot land in
/// `integration_connections` and be addressed later.
export function providerForSlug(slug: string): string | undefined {
    return Object.keys(PROVIDERS).find((provider) => PROVIDERS[provider].slug === slug);
}
