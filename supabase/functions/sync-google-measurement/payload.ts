export type ConversionEvent =
  | "trial_started"
  | "activated"
  | "subscription_paid";

export type ConversionPayloadRow = {
  id: string;
  event: ConversionEvent;
  occurred_at: string;
  ga_client_id: string | null;
  value: number | null;
  currency: string | null;
};

const eventNames: Record<ConversionEvent, string> = {
  trial_started: "sign_up",
  activated: "first_meeting_completed",
  subscription_paid: "subscription_paid",
};

export function isValidGAClientID(value: string | null): value is string {
  return value !== null && /^\d{1,20}\.\d{1,20}$/.test(value);
}

export function buildMeasurementPayload(row: ConversionPayloadRow) {
  if (!isValidGAClientID(row.ga_client_id)) return null;

  const occurredAt = new Date(row.occurred_at);
  if (Number.isNaN(occurredAt.getTime())) return null;

  const params: Record<string, string | number> = {
    event_id: row.id,
    engagement_time_msec: 1,
    attribution_model: "last_non_direct_90d",
  };
  if (row.value != null) params.value = row.value;
  if (row.currency) params.currency = row.currency;

  return {
    client_id: row.ga_client_id,
    timestamp_micros: String(occurredAt.getTime() * 1000),
    consent: {
      ad_user_data: "GRANTED",
      ad_personalization: "DENIED",
    },
    events: [{ name: eventNames[row.event], params }],
  };
}
