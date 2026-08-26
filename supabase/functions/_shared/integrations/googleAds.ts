// Google Ads, through the broker's own proxy for it.
//
// Read-only, and not for the reason the others are. Notion and HubSpot could
// have had writes and were left without them; this one could not have. A
// campaign's status and budget are money leaving an account by the hour, and the
// distance between "Nod proposed it" and "somebody skimmed a card and pressed
// approve" is not a distance to spend real money across.
//
// It is also the one provider Nod cannot address directly. Google Ads refuses
// every request that does not carry a developer token, and a developer token is
// issued to an application rather than to a user — we have none, and the broker
// does. So the real request is nested in the body of a POST to the broker's
// Google Ads proxy, which is why this provider's `base` in the registry is a
// broker host rather than Google's.
import { ActionError, type Connection, proxy } from "./pipedream.ts";
import type { ActionHandlers } from "./registry.ts";
import { requireString } from "./params.ts";

/// Pinned to what the broker's proxy currently serves. Google Ads retires a
/// version roughly a year after it ships and changes field names between them,
/// so a version this adapter was not written against is not one it can read.
const API_VERSION = "v25";

const ROW_LIMIT = 15;
/// How many accessible accounts are expanded. Each costs one request, and the
/// list this answers is a person choosing which account they mean — a manager
/// with fifty of them wants the ones they work in, not all fifty.
const ACCOUNT_LIMIT = 5;

/// The date windows a question can ask for.
///
/// A closed set rather than a passed-through expression, unlike GitHub's and
/// Gmail's search syntax. This one is interpolated into a query language, and
/// the account id beside it is checked against a pattern — between them, nothing
/// the model writes reaches GAQL unchecked.
const RANGES = [
    "TODAY",
    "YESTERDAY",
    "LAST_7_DAYS",
    "LAST_14_DAYS",
    "LAST_30_DAYS",
    "THIS_MONTH",
    "LAST_MONTH",
];

/// A customer id, or a manager's and a customer's. Google prints ids with dashes
/// and people paste them that way.
const ACCOUNT = /^(\d{6,12})(?:\/(\d{6,12}))?$/;

interface Account {
    customer: string;
    /// The manager account the query is made through, when the customer sits
    /// under one. Google refuses a client account addressed without it.
    manager?: string;
}

interface Row {
    customer?: { currencyCode?: string };
    campaign?: { id?: string; name?: string; status?: string };
    adGroup?: { name?: string };
    adGroupCriterion?: { keyword?: { text?: string; matchType?: string } };
    customerClient?: {
        id?: string;
        descriptiveName?: string;
        currencyCode?: string;
        manager?: boolean;
    };
    metrics?: Record<string, string | number>;
}

function account(params: Record<string, unknown>): Account {
    const reference = requireString(params, "account").replace(/-/g, "");
    const parts = ACCOUNT.exec(reference);
    if (!parts) {
        throw new ActionError(
            "invalid_params",
            `"${reference}" is not an ads account. Use the \`account\` value from google-ads_list_accounts.`,
        );
    }
    const [, first, second] = parts;
    return second ? { customer: second, manager: first } : { customer: first };
}

function dateRange(params: Record<string, unknown>): string {
    const value = typeof params.range === "string" ? params.range.trim().toUpperCase() : "";
    if (!value) return "LAST_30_DAYS";
    if (!RANGES.includes(value)) {
        throw new ActionError("invalid_params", `\`range\` must be one of ${RANGES.join(", ")}.`);
    }
    return value;
}

/// One call to Google Ads, wrapped the way the broker's proxy takes it: the real
/// method and path travel in the body, and the call itself is always a POST.
async function call(
    connection: Connection,
    path: string,
    method: "get" | "post",
    data: unknown,
    manager?: string,
): Promise<Record<string, unknown> | null> {
    return await proxy(connection, "", {
        method,
        url: `/${API_VERSION}${path}`,
        ...(manager ? { headers: { "login-customer-id": manager } } : {}),
        ...(data ? { data } : {}),
    }) as Record<string, unknown> | null;
}

async function search(connection: Connection, target: Account, query: string): Promise<Row[]> {
    const payload = await call(
        connection,
        `/customers/${target.customer}/googleAds:search`,
        "post",
        { query },
        target.manager,
    );
    return (payload?.results as Row[] | undefined) ?? [];
}

/// Google reports money in millionths of the account's currency. Nobody says
/// "four hundred and twelve million micros", so it is spent here rather than
/// left for the model to divide and get wrong.
function money(micros: string | number | undefined): number {
    return Math.round(Number(micros ?? 0) / 10_000) / 100;
}

function count(value: string | number | undefined): number {
    return Number(value ?? 0);
}

function performance(metrics: Row["metrics"], currency: string | undefined) {
    return {
        impressions: count(metrics?.impressions),
        clicks: count(metrics?.clicks),
        cost: money(metrics?.costMicros),
        currency,
        conversions: count(metrics?.conversions),
    };
}

export const GOOGLE_ADS_ACTIONS: ActionHandlers = {
    /// The ad accounts this login can spend in, and the reference every other
    /// action here needs.
    ///
    /// Manager accounts are left out. They hold no campaigns of their own, so
    /// one offered as a choice is a question that comes back empty and reads
    /// like "there was no spend" rather than "that was the wrong account".
    list_accounts: async (connection) => {
        const payload = await call(connection, "/customers:listAccessibleCustomers", "get", null);
        const reachable = ((payload?.resourceNames as string[] | undefined) ?? [])
            .map((name) => name.split("/").pop())
            .filter((id): id is string => !!id)
            .slice(0, ACCOUNT_LIMIT);

        // A login reaches each of these independently, so one that has been
        // suspended since it was granted must not take the whole list with it.
        const expanded = await Promise.all(reachable.map(async (login) => {
            const rows = await search(connection, { customer: login, manager: login }, [
                "SELECT customer_client.id, customer_client.descriptive_name,",
                "customer_client.currency_code, customer_client.manager",
                "FROM customer_client WHERE customer_client.status = 'ENABLED'",
            ].join(" ")).catch(() => [] as Row[]);
            return rows.map((row) => ({ login, client: row.customerClient }));
        }));

        const accounts = new Map<string, unknown>();
        for (const { login, client } of expanded.flat()) {
            if (!client?.id || client.manager === true) continue;
            const reference = client.id === login ? login : `${login}/${client.id}`;
            if (accounts.has(reference)) continue;
            accounts.set(reference, {
                account: reference,
                name: client.descriptiveName,
                currency: client.currencyCode,
            });
        }
        return { accounts: [...accounts.values()] };
    },

    /// What the campaigns did over a window, and what the account did in total.
    ///
    /// The total is a separate query rather than a sum of the rows: the rows stop
    /// at the fifteen biggest spenders, and adding those up would report a number
    /// smaller than the account actually spent while looking like the answer.
    campaign_performance: async (connection, params) => {
        const target = account(params);
        const range = dateRange(params);

        const [totals, campaigns] = await Promise.all([
            search(connection, target, [
                "SELECT customer.currency_code, metrics.impressions, metrics.clicks,",
                "metrics.cost_micros, metrics.conversions",
                `FROM customer WHERE segments.date DURING ${range}`,
            ].join(" ")),
            search(connection, target, [
                "SELECT campaign.id, campaign.name, campaign.status, customer.currency_code,",
                "metrics.impressions, metrics.clicks, metrics.cost_micros, metrics.conversions,",
                "metrics.ctr, metrics.average_cpc",
                `FROM campaign WHERE segments.date DURING ${range}`,
                `ORDER BY metrics.cost_micros DESC LIMIT ${ROW_LIMIT}`,
            ].join(" ")),
        ]);

        const currency = totals[0]?.customer?.currencyCode ?? campaigns[0]?.customer?.currencyCode;
        return {
            account: params.account,
            range,
            totals: totals[0] ? performance(totals[0].metrics, currency) : null,
            campaigns: campaigns.map((row) => ({
                id: row.campaign?.id,
                name: row.campaign?.name,
                status: row.campaign?.status,
                ...performance(row.metrics, currency),
                // Google reports the rate as a fraction; a percentage is what
                // anybody says out loud.
                ctr: Math.round(Number(row.metrics?.ctr ?? 0) * 10_000) / 100,
                cost_per_click: money(row.metrics?.averageCpc),
            })),
        };
    },

    /// The keywords that spent the most over a window.
    ///
    /// Ordered by cost rather than by clicks, because the question somebody asks
    /// out loud is which of these is burning money, and a keyword with no
    /// conversions at the top of this list is the answer to it.
    keyword_performance: async (connection, params) => {
        const target = account(params);
        const range = dateRange(params);

        const rows = await search(connection, target, [
            "SELECT campaign.name, ad_group.name, ad_group_criterion.keyword.text,",
            "ad_group_criterion.keyword.match_type, customer.currency_code,",
            "metrics.impressions, metrics.clicks, metrics.cost_micros, metrics.conversions",
            `FROM keyword_view WHERE segments.date DURING ${range} AND metrics.impressions > 0`,
            `ORDER BY metrics.cost_micros DESC LIMIT ${ROW_LIMIT}`,
        ].join(" "));

        const currency = rows[0]?.customer?.currencyCode;
        return {
            account: params.account,
            range,
            keywords: rows.map((row) => ({
                keyword: row.adGroupCriterion?.keyword?.text,
                match: row.adGroupCriterion?.keyword?.matchType,
                campaign: row.campaign?.name,
                ad_group: row.adGroup?.name,
                ...performance(row.metrics, currency),
            })),
        };
    },
};
