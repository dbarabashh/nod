import { adminClient } from "../_shared/supabase.ts";
import { json } from "../_shared/http.ts";
import { buildMeasurementPayload, isValidGAClientID } from "./payload.ts";

const SYNC_SECRET = Deno.env.get("ANALYTICS_SYNC_SECRET");
const MEASUREMENT_ID = Deno.env.get("GA4_MEASUREMENT_ID");
const API_SECRET = Deno.env.get("GA4_API_SECRET");

type ConversionRow = {
  id: string;
  event: "trial_started" | "activated" | "subscription_paid";
  occurred_at: string;
  ga_client_id: string | null;
  value: number | null;
  currency: string | null;
  attempt_count: number;
};

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "Method Not Allowed" }, 405);
  if (!SYNC_SECRET || req.headers.get("x-sync-secret") !== SYNC_SECRET) {
    return json({ error: "Unauthorized" }, 401);
  }
  if (!MEASUREMENT_ID || !API_SECRET) {
    return json({ error: "Server misconfigured" }, 500);
  }

  const admin = adminClient();
  const { data, error } = await admin
    .from("google_conversion_outbox")
    .select("id,event,occurred_at,ga_client_id,value,currency,attempt_count")
    .in("status", ["pending", "failed"])
    .lt("attempt_count", 10)
    .order("created_at", { ascending: true })
    .limit(25);
  if (error) return json({ error: error.message }, 500);

  let sent = 0;
  let failed = 0;
  let suppressed = 0;
  for (const row of (data ?? []) as ConversionRow[]) {
    const result = await sendConversion(row);
    const status = result.status;
    const { error: updateError } = await admin
      .from("google_conversion_outbox")
      .update({
        status,
        attempt_count: row.attempt_count + 1,
        last_attempt_at: new Date().toISOString(),
        last_error: result.error,
        sent_at: status === "sent" ? new Date().toISOString() : null,
        transport_accepted_at: status === "sent"
          ? new Date().toISOString()
          : null,
        validation_status: status === "sent"
          ? "not_validated"
          : "not_attempted",
      })
      .eq("id", row.id);
    if (updateError) return json({ error: updateError.message }, 500);
    if (status === "sent") sent += 1;
    if (status === "failed") failed += 1;
    if (status === "suppressed") suppressed += 1;
  }

  return json(
    { processed: (data ?? []).length, sent, failed, suppressed },
    200,
  );
});

async function sendConversion(row: ConversionRow): Promise<{
  status: "sent" | "failed" | "suppressed";
  error: string | null;
}> {
  if (!isValidGAClientID(row.ga_client_id)) {
    return { status: "suppressed", error: "invalid ga_client_id" };
  }
  if (Date.now() - new Date(row.occurred_at).getTime() > 72 * 60 * 60 * 1000) {
    return { status: "suppressed", error: "conversion older than 72 hours" };
  }

  const payload = buildMeasurementPayload(row);
  if (!payload) {
    return { status: "suppressed", error: "invalid measurement payload" };
  }

  const response = await fetch(
    `https://www.google-analytics.com/mp/collect?measurement_id=${
      encodeURIComponent(MEASUREMENT_ID!)
    }&api_secret=${encodeURIComponent(API_SECRET!)}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    },
  );
  if (response.ok) return { status: "sent", error: null };
  return {
    status: "failed",
    error: `${response.status} ${(await response.text()).slice(0, 300)}`,
  };
}
