import { adminClient } from "../_shared/supabase.ts";
import { json } from "../_shared/http.ts";

const SYNC_SECRET = Deno.env.get("ANALYTICS_SYNC_SECRET");
const CLIENT_ID = Deno.env.get("GOOGLE_ADS_CLIENT_ID");
const CLIENT_SECRET = Deno.env.get("GOOGLE_ADS_CLIENT_SECRET");
const REFRESH_TOKEN = Deno.env.get("GOOGLE_ADS_REFRESH_TOKEN");
const DEVELOPER_TOKEN = Deno.env.get("GOOGLE_ADS_DEVELOPER_TOKEN");
const CUSTOMER_ID = Deno.env.get("GOOGLE_ADS_CUSTOMER_ID")?.replaceAll("-", "");
const LOGIN_CUSTOMER_ID = Deno.env.get("GOOGLE_ADS_LOGIN_CUSTOMER_ID")?.replaceAll("-", "");

type GoogleAdsResult = {
    customer?: { currencyCode?: string };
    campaign?: { id?: string; name?: string };
    segments?: { date?: string };
    metrics?: { impressions?: string; clicks?: string; costMicros?: string };
};

Deno.serve(async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return json({ error: "Method Not Allowed" }, 405);
    if (!SYNC_SECRET || req.headers.get("x-sync-secret") !== SYNC_SECRET) {
        return json({ error: "Unauthorized" }, 401);
    }
    if (!CLIENT_ID || !CLIENT_SECRET || !REFRESH_TOKEN || !DEVELOPER_TOKEN || !CUSTOMER_ID) {
        return json({ error: "Server misconfigured" }, 500);
    }

    const accessToken = await refreshAccessToken();
    if (!accessToken) return json({ error: "Google OAuth refresh failed" }, 502);

    const end = isoDay(new Date());
    const start = isoDay(new Date(Date.now() - 89 * 24 * 60 * 60 * 1000));
    const query = `
        SELECT
          customer.currency_code,
          campaign.id,
          campaign.name,
          segments.date,
          metrics.impressions,
          metrics.clicks,
          metrics.cost_micros
        FROM campaign
        WHERE segments.date BETWEEN '${start}' AND '${end}'
          AND campaign.status != 'REMOVED'
    `;
    const headers: Record<string, string> = {
        Authorization: `Bearer ${accessToken}`,
        "developer-token": DEVELOPER_TOKEN,
        "Content-Type": "application/json",
    };
    if (LOGIN_CUSTOMER_ID) headers["login-customer-id"] = LOGIN_CUSTOMER_ID;

    const response = await fetch(
        `https://googleads.googleapis.com/v25/customers/${CUSTOMER_ID}/googleAds:searchStream`,
        { method: "POST", headers, body: JSON.stringify({ query }) },
    );
    if (!response.ok) {
        return json({ error: `${response.status} ${(await response.text()).slice(0, 500)}` }, 502);
    }

    const batches = await response.json() as Array<{ results?: GoogleAdsResult[] }>;
    const rows = batches.flatMap((batch) => batch.results ?? []).flatMap((result) => {
        const day = result.segments?.date;
        const campaignId = result.campaign?.id;
        const currency = result.customer?.currencyCode;
        if (!day || !campaignId || !currency) return [];
        return [{
            day,
            customer_id: CUSTOMER_ID,
            campaign_id: campaignId,
            campaign_name: result.campaign?.name ?? campaignId,
            currency,
            impressions: result.metrics?.impressions ?? "0",
            clicks: result.metrics?.clicks ?? "0",
            cost_micros: result.metrics?.costMicros ?? "0",
            synced_at: new Date().toISOString(),
        }];
    });

    if (rows.length > 0) {
        const { error } = await adminClient()
            .from("google_ads_campaign_daily")
            .upsert(rows, { onConflict: "day,customer_id,campaign_id" });
        if (error) return json({ error: error.message }, 500);
    }
    return json({ start, end, rows: rows.length }, 200);
});

async function refreshAccessToken(): Promise<string | null> {
    const body = new URLSearchParams({
        client_id: CLIENT_ID!,
        client_secret: CLIENT_SECRET!,
        refresh_token: REFRESH_TOKEN!,
        grant_type: "refresh_token",
    });
    const response = await fetch("https://oauth2.googleapis.com/token", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body,
    });
    if (!response.ok) return null;
    const payload = await response.json() as { access_token?: string };
    return payload.access_token ?? null;
}

function isoDay(date: Date): string {
    return date.toISOString().slice(0, 10);
}
