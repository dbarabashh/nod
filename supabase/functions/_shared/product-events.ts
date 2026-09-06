// The vocabulary `_valid_product_event_properties` admits for `plan`. The
// catalogue spells the workspace plan `teams`; the validator spells it `team`,
// and a row it rejects is a funnel event silently lost.
const EVENT_PLANS = new Set(["trial", "starter", "pro", "team"]);

export function eventPlan(plan: unknown): string {
  if (plan === "teams") return "team";
  return typeof plan === "string" && EVENT_PLANS.has(plan) ? plan : "unknown";
}
