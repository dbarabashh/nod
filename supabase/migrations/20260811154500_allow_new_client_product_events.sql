-- `product_events` has two gates, and only one of them was widened.
--
-- `20260811154000` extended the table's CHECK constraint, but the RPC the client
-- actually calls — `record_product_events`, the only event writer granted to
-- `authenticated` — carries its own hardcoded copy of the list. The four new
-- client events (allowance gate, referral share, consent saved) were therefore
-- accepted by the table and rejected by the RPC as `invalid_event`: recorded in
-- `product_event_rejections` and silently dropped.
--
-- The duplicate list is the actual defect, so it becomes one named function.
-- It stays a separate list from the table constraint on purpose: the table also
-- admits SERVER-only events, and a client must not be able to forge those.
-- `topup_checkout_started`, `topup_purchased` and `checkout_started` are written
-- exclusively by edge functions from provider truth — accepting them from a
-- client would let anyone fabricate revenue in the founder dashboard.
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
        'email_consent_saved'
    ]::text[];
$$;

revoke all on function public._client_product_events() from public, anon, authenticated;

create or replace function public.record_product_events(p_events jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := auth.uid();
    v_item jsonb;
    v_id uuid;
    v_inserted integer;
    v_accepted integer := 0;
    v_duplicates integer := 0;
    v_rejected integer := 0;
    v_properties jsonb;
    v_occurred_at timestamptz;
    v_allowed text[] := public._client_product_events();
begin
    if v_user_id is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if jsonb_typeof(p_events) <> 'array' or jsonb_array_length(p_events) > 25 then
        insert into public.product_event_rejections (user_id, reason_code)
        values (v_user_id, 'invalid_batch');
        return jsonb_build_object('accepted', 0, 'duplicates', 0, 'rejected', 1);
    end if;

    for v_item in select value from jsonb_array_elements(p_events)
    loop
        v_properties := coalesce(v_item -> 'properties', '{}'::jsonb);
        if coalesce(v_item ->> 'id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
           or coalesce(v_item ->> 'app_session_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
           or (v_item ->> 'capture_id' is not null and v_item ->> 'capture_id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') then
            insert into public.product_event_rejections (user_id, platform, reason_code)
            values (v_user_id, nullif(v_item ->> 'platform', ''), 'invalid_identifier');
            v_rejected := v_rejected + 1;
            continue;
        end if;
        if not (coalesce(v_item ->> 'event', '') = any(v_allowed))
          or coalesce(v_item ->> 'platform', '') not in ('macos', 'ios')
          or coalesce(v_item ->> 'app_version', '') !~ '^[0-9A-Za-z.+-]{1,32}$' then
            insert into public.product_event_rejections (user_id, platform, reason_code)
            values (
                v_user_id,
                case when v_item ->> 'platform' in ('macos', 'ios') then v_item ->> 'platform' end,
                'invalid_event'
            );
            v_rejected := v_rejected + 1;
            continue;
        end if;
        if not public._valid_product_event_properties(v_properties) then
            insert into public.product_event_rejections (user_id, platform, reason_code)
            values (v_user_id, v_item ->> 'platform', 'invalid_properties');
            v_rejected := v_rejected + 1;
            continue;
        end if;
        begin
            v_occurred_at := (v_item ->> 'occurred_at')::timestamptz;
        exception when others then
            v_occurred_at := null;
        end;
        if v_occurred_at is null
           or v_occurred_at < now() - interval '7 days'
           or v_occurred_at > now() + interval '5 minutes' then
            insert into public.product_event_rejections (user_id, platform, reason_code)
            values (v_user_id, v_item ->> 'platform', 'invalid_timestamp');
            v_rejected := v_rejected + 1;
            continue;
        end if;

        v_id := (v_item ->> 'id')::uuid;
        insert into public.product_events (
            id, user_id, occurred_at, app_session_id, capture_id, event,
            platform, app_version, properties
        ) values (
            v_id,
            v_user_id,
            v_occurred_at,
            (v_item ->> 'app_session_id')::uuid,
            nullif(v_item ->> 'capture_id', '')::uuid,
            v_item ->> 'event',
            v_item ->> 'platform',
            left(coalesce(nullif(v_item ->> 'app_version', ''), '0'), 32),
            v_properties
        ) on conflict (id) do nothing;
        get diagnostics v_inserted = row_count;
        if v_inserted = 1 then
            v_accepted := v_accepted + 1;
        else
            v_duplicates := v_duplicates + 1;
        end if;
    end loop;

    return jsonb_build_object(
        'accepted', v_accepted,
        'duplicates', v_duplicates,
        'rejected', v_rejected
    );
end;
$$;

revoke all on function public.record_product_events(jsonb) from public, anon;
grant execute on function public.record_product_events(jsonb) to authenticated;
