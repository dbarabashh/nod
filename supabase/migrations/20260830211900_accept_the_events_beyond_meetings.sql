-- Accept the events for the parts of Nod that are not a meeting.
--
-- The allow-list was drawn when a meeting was the product: every event on it is
-- about capturing one, viewing one, or paying to keep doing it. A recording is
-- now one input among several, and the four surfaces that carry the rest of the
-- product report nothing at all — connected products, the live lookup into
-- them, the approval card in front of a write, and the screen-reading switch.
--
-- Four events, and no more than four. Each answers a question the domain
-- records cannot:
--
--   integration_connected / _revoked  `integration_connections` has the current
--       state, not the transitions — an account that connected Slack and dropped
--       it a week later reads identically to one that never did.
--   lookup_routed  whether the products *answer*. Linking is measured already;
--       being useful is not, and an account with Linear connected that never
--       gets an answer out of it fails in a way a connection table calls success.
--   tool_call_reviewed  whether the approval gate protects more than it
--       interrupts. Nothing else records a refusal — a declined write leaves the
--       account exactly as it was.
--   ambient_context_toggled  `screen_observations` gives adoption and intensity,
--       but its absence is ambiguous: off, paused, blocklisted, or the Mac shut.
--       Only the transition separates them, and "turned it back off" is the
--       signal worth having.
--
-- What is deliberately NOT accepted, and must not be added later without
-- reopening `privacy.md` § 3.8: the app a screen capture came from, a window
-- title, a blocklist's contents, a question, an answer. Those are the tempting
-- numbers here and the ones the policy rules out by name.

create or replace function public._client_product_events()
returns text[]
language sql
immutable
set search_path = ''
as $$
    select array[
        'app_opened',
        'capture_start_requested',
        'capture_started',
        'capture_stopped',
        'capture_failed',
        'capture_discarded',
        'summary_viewed',
        'transcript_viewed',
        'action_items_viewed',
        'content_copied',
        'meeting_exported',
        'ai_action_completed',
        'paywall_viewed',
        'allowance_gate_viewed',
        'allowance_gate_action',
        'referral_nudge_viewed',
        'referral_link_shared',
        'email_consent_saved',
        'integration_connected',
        'integration_revoked',
        'lookup_routed',
        'tool_call_reviewed',
        'ambient_context_toggled'
    ]::text[];
$$;

-- Same grants as the definition it replaces: the ingest function is the only
-- caller, and it is `security definer`.
revoke all on function public._client_product_events() from public, anon, authenticated;
grant execute on function public._client_product_events() to service_role;
