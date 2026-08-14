// org-invite — creates an organization invite and emails it.
//
// Deliberately not routed through `email_outbox`. That queue exists for
// campaigns addressed to *users*: it carries a `user_id` that is NOT NULL and a
// foreign key into `auth.users`, plus claims, cooldowns and per-user consent
// state. An invite goes to somebody who by definition may have no account yet,
// and none of that machinery has an answer for them. Widening the queue's
// invariants to fit one message that isn't a campaign would cost more than
// sending this one directly.
//
// What is not skipped is suppression. Somebody who unsubscribed or hard-bounced
// stays unsubscribed, and that list is keyed by address rather than by user, so
// it applies here exactly as it does there.
//
// Authorization is the RPC's, not this function's: `invite_to_organization`
// runs under the caller's JWT and refuses anyone who is not an administrator of
// the organization. This file never touches the service role for that decision.
//
// Request  (POST /functions/v1/org-invite):
//   { "orgId": "…", "email": "…", "role": "member", "teamId": null }
// Response: { "inviteUrl": "…", "emailed": true }
import { createClient } from "jsr:@supabase/supabase-js@2";

import { json } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const RESEND_API_BASE = Deno.env.get("RESEND_API_BASE") ?? "https://api.resend.com";
const INVITE_BASE_URL = Deno.env.get("INVITE_BASE_URL") ?? "https://hellonod.app";

// An invite is sent on the organization's behalf, not by whoever happens to be
// on support that week, so it comes from the team address rather than a person's.
// Replies land somewhere a human reads: an invite is the message most likely to
// get "who are you and why am I getting this?" as an answer.
const FROM = "Nod <team@hellonod.app>";
const REPLY_TO = "team@hellonod.app";
const TEMPLATE_ALIAS = "organization-invite-v1-en";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return json({ error: "Unauthenticated" }, 401);
  }

  const body = await req.json().catch(() => null);
  const orgId = body?.orgId;
  const email = body?.email;
  if (typeof orgId !== "string" || typeof email !== "string") {
    return json({ error: "`orgId` and `email` are required" }, 400);
  }

  // The caller's own client: the RPC's administrator check reads `auth.uid()`,
  // so it has to see the caller and not us.
  const caller = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });

  const { data, error } = await caller.rpc("invite_to_organization", {
    p_org: orgId,
    p_email: email,
    p_role: typeof body?.role === "string" ? body.role : "member",
    p_team: typeof body?.teamId === "string" ? body.teamId : null,
  });

  if (error) {
    console.warn(`org-invite rejected: ${error.message}`);
    // The RPC's messages are written to be read by the person inviting —
    // "already a member", "only an owner can invite an owner" — so they are
    // passed through rather than replaced with something generic.
    return json({ error: error.message }, 400);
  }

  const invite = data as {
    token: string;
    org_name: string;
    inviter: string;
    role: string;
    email: string;
  };
  const inviteUrl = `${INVITE_BASE_URL.replace(/\/+$/, "")}/invite/${invite.token}`;

  const emailed = await deliver(invite, inviteUrl);
  console.info(`org-invite created emailed=${emailed}`);

  // The link comes back either way. A send we could not make is a reason to let
  // the administrator pass it on themselves, not a reason to lose the invite
  // that was already created.
  return json({ inviteUrl, emailed }, 200);
});

async function deliver(
  invite: { org_name: string; inviter: string; role: string; email: string },
  inviteUrl: string,
): Promise<boolean> {
  if (!RESEND_API_KEY) {
    console.warn("org-invite: RESEND_API_KEY is not set");
    return false;
  }

  const { data: suppressed } = await adminClient()
    .from("email_suppressions")
    .select("email")
    .eq("email", invite.email)
    .eq("scope", "all_email")
    .maybeSingle();
  if (suppressed) {
    console.info("org-invite: address is suppressed");
    return false;
  }

  try {
    const response = await fetch(`${RESEND_API_BASE}/emails`, {
      method: "POST",
      signal: AbortSignal.timeout(20_000),
      headers: {
        "Authorization": `Bearer ${RESEND_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: FROM,
        reply_to: REPLY_TO,
        to: invite.email,
        template: {
          id: TEMPLATE_ALIAS,
          variables: {
            ORG_NAME: invite.org_name,
            INVITER: invite.inviter,
            ROLE: invite.role,
            INVITE_URL: inviteUrl,
          },
        },
      }),
    });
    if (!response.ok) {
      console.error(`org-invite send failed: ${response.status}`);
      return false;
    }
    return true;
  } catch (error) {
    console.error(`org-invite send threw: ${error}`);
    return false;
  }
}
