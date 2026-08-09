export type PaidSubscriptionTransaction = {
  transactionId: string;
  subscriptionId: string;
  customerId: string | null;
  currency: string;
  value: number;
};

export function paidSubscriptionTransaction(
  data: Record<string, unknown>,
): PaidSubscriptionTransaction | null {
  const transactionId = stringValue(data.id);
  const subscriptionId = stringValue(data.subscription_id);
  const customerId = nullableString(data.customer_id);
  const currency = stringValue(data.currency_code).toUpperCase();
  const details = objectValue(data.details);
  const totals = objectValue(details.totals);
  const earnings = stringValue(totals.earnings);
  const value = currencyAmount(earnings, currency);

  if (
    !transactionId || !subscriptionId || !currency || value === null ||
    value <= 0
  ) {
    return null;
  }

  return { transactionId, subscriptionId, customerId, currency, value };
}

export function currencyAmount(
  minorUnits: string,
  currency: string,
): number | null {
  if (!/^-?\d+$/.test(minorUnits) || !/^[A-Z]{3}$/.test(currency)) return null;

  try {
    const digits = new Intl.NumberFormat("en", {
      style: "currency",
      currency,
    }).resolvedOptions().maximumFractionDigits ?? 2;
    const value = Number(minorUnits) / 10 ** digits;
    return Number.isFinite(value) ? value : null;
  } catch {
    return null;
  }
}

function objectValue(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function nullableString(value: unknown): string | null {
  const valueString = stringValue(value);
  return valueString || null;
}
