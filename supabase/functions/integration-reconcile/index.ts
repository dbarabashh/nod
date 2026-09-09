// integration-reconcile — the only writer of `integration_connections`.
//
// Connect's connection webhook is not signed, so unlike the broker we replaced,
// nothing that arrives here is evidence. What arrives is a *hint* that one
// person's connections may have changed; the row is then written from what
// Connect itself reports for that person and nothing else. A forged delivery can
// therefore do no more than make us re-read the truth.
//
// Two callers, one body of work:
//   • Pipedream, posting `CONNECTION_SUCCESS` with no Supabase JWT.
//   • The app, on a timer after the browser flow, so a user who beat the
//     webhook still sees "Connected" without waiting.
//
// That second caller is why the writes below are conditional. This runs every
// couple of seconds while somebody waits on a spinner, and the two side effects
// it carries — revoking what the broker no longer holds, and importing a
// company's roster — are far too expensive and too destructive to repeat on a
// timer. Revoking fires `purge_provider_data`, which deletes the calendar this
// account had already synced.
//
// Request  (POST /functions/v1/integration-reconcile): a Connect webhook body,
//          or an authenticated call with no body at all.
// Response: { "connected": ["linear", …] }
import { json } from "../_shared/http.ts";
import { adminClient, authenticate } from "../_shared/supabase.ts";
import { brokerGET, connectURL, isConfigured } from "../_shared/integrations/pipedream.ts";
import { directoryTargetOrg, importDirectory, isDirectorySource } from "../_shared/integrations/directory.ts";
import { barredUsers } from "../_shared/integrations/policy.ts";
import { apiBase, providerForSlug } from "../_shared/integrations/registry.ts";
import { diff, type Live } from "./diff.ts";

interface ConnectAccount {
  id: string;
  external_id: string;
  app?: { name_slug?: string };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }
  if (!isConfigured) {
    console.error("pipedream connect is not configured");
    return json({ error: "Integrations unavailable" }, 503);
  }

  const userId = await subject(req);
  if (!userId) {
    // Deliberately not an error: an unsigned webhook we cannot place is noise,
    // and a non-2xx would only buy a retry loop of the same noise.
    return json({ ok: true }, 200);
  }

  const live = await liveConnections(userId);
  if (live === null) return json({ error: "Could not read your connections" }, 502);

  const admin = adminClient();
  const { data: stored, error: readError } = await admin
    .from("integration_connections")
    .select("provider, broker_account_id")
    .eq("user_id", userId)
    .is("revoked_at", null);

  if (readError) {
    console.error(`integration_connections read failed: ${readError.message}`);
    return json({ error: "Could not read your connections" }, 500);
  }

  const { arrived, departed, nowLive } = diff(
    (stored ?? []).map((row) => ({
      provider: row.provider as string,
      accountId: row.broker_account_id as string,
    })),
    live,
  );

  // Nothing moved. The overwhelmingly common case while a spinner polls, and
  // the whole reason this function reads before it writes.
  if (arrived.length === 0 && departed.length === 0) {
    return json({ connected: nowLive }, 200);
  }

  if (arrived.length > 0) {
    const now = new Date().toISOString();
    // Reconnecting mints a fresh account, so the row is replaced rather than
    // added to: one live link per user per provider.
    const { error } = await admin
      .from("integration_connections")
      .upsert(
        arrived.map((entry) => ({
          user_id: userId,
          provider: entry.provider,
          broker_account_id: entry.accountId,
          connected_at: now,
          revoked_at: null,
        })),
        { onConflict: "user_id,provider" },
      );
    if (error) {
      console.error(`integration_connections upsert failed: ${error.message}`);
      return json({ error: "Could not store connection" }, 500);
    }
  }

  // Whatever Connect no longer reports, the user ended on the provider's own
  // screen. Revoking here is what keeps a row from outliving the grant behind
  // it — the trigger on this table clears the data that came with it, which is
  // also why it must never run on a provider that is merely mid-refresh.
  if (departed.length > 0) {
    const { error } = await admin
      .from("integration_connections")
      .update({ revoked_at: new Date().toISOString() })
      .eq("user_id", userId)
      .in("provider", departed)
      .is("revoked_at", null);
    if (error) console.error(`integration_connections revoke failed: ${error.message}`);
  }

  console.info(`integrations reconciled: +${arrived.length} -${departed.length}`);
  await importDirectories(userId, arrived);
  return json({ connected: nowLive }, 200);
});

/// Whose connections to reconcile.
///
/// A Supabase JWT is proof; a webhook body is a claim. Both are only ever used
/// to *scope* the read that follows, so the weaker one cannot widen it.
async function subject(req: Request): Promise<string | null> {
  const raw = await req.text();

  const auth = await authenticate(req);
  if (!(auth instanceof Response)) return auth.user.id;

  const event = raw ? JSON.parse(raw) as Record<string, unknown> : null;
  if (event?.event !== "CONNECTION_SUCCESS") return null;
  const external = (event.account as ConnectAccount | undefined)?.external_id;
  return typeof external === "string" && external.length > 0 ? external : null;
}

/// What Connect currently holds for this person, or null if we could not ask.
///
/// Scoped by `external_user_id` at the API rather than filtered afterwards: the
/// request cannot return somebody else's account, so there is no code path in
/// which one could be written.
///
/// An unhealthy account is deliberately still an account. `healthy` goes false
/// while a token refreshes, and treating that as "disconnected" would revoke a
/// live grant — and take the synced calendar with it — for the length of one
/// refresh.
async function liveConnections(userId: string): Promise<Live[] | null> {
  const payload = await brokerGET(
    `${connectURL("accounts")}?external_user_id=${encodeURIComponent(userId)}`,
  );
  if (payload === null) return null;

  const data = (payload as { data?: unknown }).data;
  if (!Array.isArray(data)) return [];

  const live: Live[] = [];
  for (const account of data as ConnectAccount[]) {
    const slug = account.app?.name_slug;
    if (!slug) continue;
    // Ours by name where we have adapters, by the broker's slug otherwise. Both
    // are the same kind of identifier; only `registry.ts` decides which of them
    // Nod can act in.
    live.push({ provider: providerForSlug(slug) ?? slug, accountId: account.id });
  }
  return live;
}

/// The moment a company's stack is connected is the moment its roster can be
/// read, and reading it is what makes the product usable before anybody has been
/// invited to Nod. Administrators only — a member linking their own account is
/// not setting the company up, and their workspace's members are not the
/// company's colleagues.
///
/// Only for connections that just arrived, and outside their success path: a
/// directory we could not read is a slower first run, not a failed connection.
async function importDirectories(userId: string, arrived: Live[]): Promise<void> {
  const sources = arrived.filter((entry) => isDirectorySource(entry.provider));
  if (sources.length === 0) return;
  try {
    const admin = adminClient();
    const orgId = await directoryTargetOrg(admin, userId);
    if (!orgId) return;
    for (const entry of sources) {
      // Connecting a product the organization forbade is allowed — the grant is
      // the person's and a policy can be lifted — but reading its roster on the
      // strength of it is the acting the policy is about.
      if ((await barredUsers([userId], entry.provider)).has(userId)) {
        console.info(`directory import skipped: ${entry.provider} not permitted`);
        continue;
      }
      await importDirectory(admin, {
        id: entry.accountId,
        provider: entry.provider,
        externalUserId: userId,
        base: apiBase(entry.provider) ?? "",
      }, orgId);
    }
  } catch (error) {
    console.warn(`directory import after connecting failed: ${error}`);
  }
}
