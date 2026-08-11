-- The allowance gate, the top-up purchase and the referral surfaces are where
-- the new money is, and none of them emitted a single event. Extend the
-- product-event contract rather than inventing a second analytics path.
--
-- `billing` gains 'one_time' because a top-up is neither monthly nor yearly, and
-- `entry_point` gains 'notch' + 'email' so a gate shown in the capture surface is
-- distinguishable from the same offer opened from Settings.

alter table public.product_events
    drop constraint product_events_event_check;

alter table public.product_events
    add constraint product_events_event_check check (event in (
        'app_opened', 'capture_start_requested', 'capture_started', 'capture_stopped',
        'capture_failed', 'capture_discarded', 'summary_viewed', 'transcript_viewed',
        'action_items_viewed', 'content_copied', 'meeting_exported',
        'ai_action_completed', 'paywall_viewed', 'checkout_started',
        -- Allowance and top-up funnel.
        'allowance_gate_viewed', 'allowance_gate_action', 'topup_checkout_started', 'topup_purchased',
        -- Referral surfaces.
        'referral_nudge_viewed', 'referral_link_shared',
        -- Consent: how many topics were chosen, never which ones.
        'email_consent_saved'
    ));

create or replace function public._valid_product_event_properties(p_properties jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
    select jsonb_typeof(coalesce(p_properties, '{}'::jsonb)) = 'object'
       and not exists (
           select 1
           from jsonb_object_keys(coalesce(p_properties, '{}'::jsonb)) key
           where key not in (
               'platform', 'app_version', 'session_kind', 'entry_point', 'stage',
               'reason_code', 'surface', 'content_type', 'ai_feature', 'outcome',
               'plan', 'billing'
           )
       )
       and (p_properties ->> 'platform' is null or p_properties ->> 'platform' in ('macos', 'ios'))
       and (p_properties ->> 'app_version' is null or p_properties ->> 'app_version' ~ '^[0-9A-Za-z.+-]{1,32}$')
       and (p_properties ->> 'session_kind' is null or p_properties ->> 'session_kind' in (
           'meeting', 'voice_note', 'media', 'conversation', 'lecture', 'meetup', 'conference'
       ))
       and (p_properties ->> 'entry_point' is null or p_properties ->> 'entry_point' in (
           'app_launch', 'menu_bar', 'main_window', 'floating_panel', 'hotkey', 'deep_link',
           'home', 'library', 'quick_capture', 'live_activity', 'meeting_detail', 'ask', 'settings',
           'notch', 'email'
       ))
       and (p_properties ->> 'stage' is null or p_properties ->> 'stage' in (
           'welcome', 'profile', 'permissions', 'tutorial', 'consent', 'authentication',
           'entitlement', 'vad', 'audio', 'capture', 'transcription', 'persistence', 'finalization'
       ))
       and (p_properties ->> 'reason_code' is null or p_properties ->> 'reason_code' in (
           'permission_denied', 'entitlement_required', 'hours_exhausted', 'vad_unavailable',
           'audio_start_failed', 'interrupted', 'route_changed', 'transcription_failed',
           'persistence_failed', 'user_cancelled', 'authentication_failed', 'unknown'
       ))
       and (p_properties ->> 'surface' is null or p_properties ->> 'surface' in (
           'onboarding', 'capture', 'home', 'library', 'meeting_detail', 'ask', 'paywall',
           'settings', 'share'
       ))
       and (p_properties ->> 'content_type' is null or p_properties ->> 'content_type' in (
           'summary', 'transcript', 'action_items', 'answer', 'meeting', 'markdown'
       ))
       and (p_properties ->> 'ai_feature' is null or p_properties ->> 'ai_feature' in (
           'catch_up', 'suggest_reply', 'key_points', 'follow_up', 'live_ask',
           'meeting_ask', 'knowledge_ask', 'recap', 'summary_regeneration'
       ))
       and (p_properties ->> 'outcome' is null or p_properties ->> 'outcome' in (
           'granted', 'declined', 'success', 'failure', 'cancelled', 'viewed'
       ))
       and (p_properties ->> 'plan' is null or p_properties ->> 'plan' in (
           'trial', 'starter', 'pro', 'team', 'unknown'
       ))
       and (p_properties ->> 'billing' is null or p_properties ->> 'billing' in (
           'monthly', 'yearly', 'one_time', 'none', 'unknown'
       ));
$$;

revoke all on function public._valid_product_event_properties(jsonb) from public, anon, authenticated;

-- Paying for hours is a conversion worth optimising ads against. `unique
-- (user_id, event)` means only a customer's FIRST top-up is reported, which is
-- the intent: repeat purchases are retention, not acquisition.
alter table public.google_conversion_outbox
    drop constraint google_conversion_outbox_event_check;

alter table public.google_conversion_outbox
    add constraint google_conversion_outbox_event_check
    check (event in ('trial_started', 'activated', 'subscription_paid', 'topup_purchased'));

-- Mirrors `enqueue_paid_transaction_conversion`, including its silence when the
-- account was never attributed to a click.
create or replace function public.enqueue_topup_conversion(
    p_user_id uuid,
    p_occurred_at timestamptz,
    p_value numeric,
    p_currency text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_touch_id uuid;
    v_ga_client_id text;
    v_rows integer;
begin
    if p_user_id is null or p_occurred_at is null or coalesce(p_value, 0) <= 0
       or p_currency is null or upper(p_currency) !~ '^[A-Z]{3}$' then
        return false;
    end if;

    select ua.last_touch_id, t.ga_client_id
      into v_touch_id, v_ga_client_id
      from public.user_acquisition ua
      join public.acquisition_touches t on t.id = ua.last_touch_id
     where ua.user_id = p_user_id
       and ua.coverage_status = 'attributed'
       and not exists (
           select 1 from public.acquisition_consent_revocations r
            where r.visitor_id = t.visitor_id
       );
    if v_touch_id is null or v_ga_client_id is null then
        return false;
    end if;

    insert into public.google_conversion_outbox (
        user_id, event, occurred_at, touch_id, ga_client_id, value, currency
    ) values (
        p_user_id, 'topup_purchased', p_occurred_at, v_touch_id, v_ga_client_id,
        p_value, upper(p_currency)
    )
    on conflict (user_id, event) do nothing;
    get diagnostics v_rows = row_count;
    return v_rows = 1;
end;
$$;

revoke all on function public.enqueue_topup_conversion(uuid, timestamptz, numeric, text) from public, anon, authenticated;
grant execute on function public.enqueue_topup_conversion(uuid, timestamptz, numeric, text) to service_role;

-- Server-side product events (the edge functions have no app session).
create or replace function public.record_server_product_event(
    p_user_id uuid,
    p_event text,
    p_properties jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.product_events (
        id, user_id, occurred_at, event, platform, app_version, properties
    ) values (
        gen_random_uuid(), p_user_id, now(), p_event, 'server', 'server',
        coalesce(p_properties, '{}'::jsonb)
    );
end;
$$;

revoke all on function public.record_server_product_event(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.record_server_product_event(uuid, text, jsonb) to service_role;
