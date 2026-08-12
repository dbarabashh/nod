-- `product_event_rejections` counted the drops without recording what was
-- dropped: a row carries a reason code and nothing identifying the event, so the
-- founder dashboard's "Rejected analytics events need contract review" names
-- nothing to review. Both writers already hold the offending item — they just
-- discarded its name.
--
-- What gets stored is the name a client claimed, which is by definition the
-- field that failed validation, so it is narrowed to an identifier shape rather
-- than kept verbatim: anything outside `[A-Za-z0-9_.-]{1,64}` lands as
-- 'malformed'. A real client sending the wrong case or a stale name is still
-- fully diagnosable, while `privacy.md` § 3.5's promise that the event log holds
-- no arbitrary free-form strings stays literally true.
--
-- `founder_measurement_health` had the mirror-image problem. It applied
-- `_excluded_user_ids()` to the accepted count but not to freshness or to the
-- rejected count, so a founder's own test traffic read as "1m ago" next to
-- "0 accepted events" — the panel looked broken while the data was fine — and a
-- single founder-authored rejection lit the danger banner. Both now honour the
-- exclusion, with the excluded rejections kept as their own number so a contract
-- break hit during development is not invisible, merely off the KPI.
--
-- The two coverage percentages returned 0 for an empty window, which the
-- dashboard paints red as though coverage had collapsed. An empty window is not
-- zero coverage: they return null now, and the dashboard renders no data.

alter table public.product_event_rejections
    add column if not exists event text;

alter table public.product_event_rejections
    drop constraint if exists product_event_rejections_event_length;

alter table public.product_event_rejections
    add constraint product_event_rejections_event_length
    check (event is null or event ~ '^[A-Za-z0-9_.-]{1,64}$');

create or replace function public._rejected_event_name(p_event text)
returns text
language sql
immutable
set search_path = ''
as $$
    select case
        when coalesce(p_event, '') = '' then null
        when p_event ~ '^[A-Za-z0-9_.-]{1,64}$' then p_event
        else 'malformed'
    end;
$$;

revoke all on function public._rejected_event_name(text) from public, anon, authenticated;

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
    v_event text;
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
        v_event := public._rejected_event_name(v_item ->> 'event');
        if coalesce(v_item ->> 'id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
           or coalesce(v_item ->> 'app_session_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
           or (v_item ->> 'capture_id' is not null and v_item ->> 'capture_id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') then
            insert into public.product_event_rejections (user_id, platform, reason_code, event)
            values (v_user_id, nullif(v_item ->> 'platform', ''), 'invalid_identifier', v_event);
            v_rejected := v_rejected + 1;
            continue;
        end if;
        if not (coalesce(v_item ->> 'event', '') = any(v_allowed))
          or coalesce(v_item ->> 'platform', '') not in ('macos', 'ios')
          or coalesce(v_item ->> 'app_version', '') !~ '^[0-9A-Za-z.+-]{1,32}$' then
            insert into public.product_event_rejections (user_id, platform, reason_code, event)
            values (
                v_user_id,
                case when v_item ->> 'platform' in ('macos', 'ios') then v_item ->> 'platform' end,
                'invalid_event',
                v_event
            );
            v_rejected := v_rejected + 1;
            continue;
        end if;
        if not public._valid_product_event_properties(v_properties) then
            insert into public.product_event_rejections (user_id, platform, reason_code, event)
            values (v_user_id, v_item ->> 'platform', 'invalid_properties', v_event);
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
            insert into public.product_event_rejections (user_id, platform, reason_code, event)
            values (v_user_id, v_item ->> 'platform', 'invalid_timestamp', v_event);
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

create or replace function public.record_onboarding_events(p_installation_id uuid, p_events jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := auth.uid();
    v_item jsonb;
    v_properties jsonb;
    v_accepted integer := 0;
    v_duplicates integer := 0;
    v_rejected integer := 0;
    v_inserted integer;
    v_platform text;
    v_event text;
    v_occurred_at timestamptz;
begin
    if p_installation_id is null or jsonb_typeof(p_events) <> 'array' or jsonb_array_length(p_events) > 25 then
        insert into public.product_event_rejections (user_id, installation_id, reason_code)
        values (v_user_id, p_installation_id, 'invalid_batch');
        return jsonb_build_object('accepted', 0, 'duplicates', 0, 'rejected', 1);
    end if;
    if v_user_id is null and (
        select count(*)
        from public.onboarding_events
        where installation_id = p_installation_id
          and created_at >= date_trunc('day', now())
    ) + jsonb_array_length(p_events) > 100 then
        insert into public.product_event_rejections (installation_id, platform, reason_code)
        values (p_installation_id, 'ios', 'rate_limited');
        return jsonb_build_object('accepted', 0, 'duplicates', 0, 'rejected', jsonb_array_length(p_events));
    end if;

    for v_item in select value from jsonb_array_elements(p_events)
    loop
        v_properties := coalesce(v_item -> 'properties', '{}'::jsonb);
        v_platform := v_item ->> 'platform';
        v_event := public._rejected_event_name(v_item ->> 'event');
        if coalesce(v_item ->> 'id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
           or coalesce(v_item ->> 'app_session_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
            insert into public.product_event_rejections (user_id, installation_id, platform, reason_code, event)
            values (v_user_id, p_installation_id, case when v_platform in ('macos', 'ios') then v_platform end, 'invalid_identifier', v_event);
            v_rejected := v_rejected + 1;
            continue;
        end if;
        if coalesce(v_platform, '') not in ('macos', 'ios')
           or (v_user_id is null and v_platform <> 'ios')
           or coalesce(v_item ->> 'event', '') not in (
               'step_shown', 'analytics_consent_resolved', 'onboarding_completed',
               'auth_started', 'auth_failed', 'profile_completed', 'profile_skipped',
               'permission_requested', 'permission_granted', 'permission_denied',
               'permission_pending_relaunch', 'permissions_skipped', 'relaunch_prompted',
               'relaunch_clicked', 'relaunch_failed'
           )
           or coalesce(v_item ->> 'app_version', '') !~ '^[0-9A-Za-z.+-]{1,32}$' then
            insert into public.product_event_rejections (user_id, installation_id, platform, reason_code, event)
            values (v_user_id, p_installation_id, case when v_platform in ('macos', 'ios') then v_platform end, 'invalid_event', v_event);
            v_rejected := v_rejected + 1;
            continue;
        end if;
        if not public._valid_product_event_properties(v_properties) then
            insert into public.product_event_rejections (user_id, installation_id, platform, reason_code, event)
            values (v_user_id, p_installation_id, v_platform, 'invalid_properties', v_event);
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
            insert into public.product_event_rejections (user_id, installation_id, platform, reason_code, event)
            values (v_user_id, p_installation_id, v_platform, 'invalid_timestamp', v_event);
            v_rejected := v_rejected + 1;
            continue;
        end if;

        insert into public.onboarding_events (
            id, user_id, installation_id, app_session_id, occurred_at,
            event, step, detail, app_version, platform
        ) values (
            (v_item ->> 'id')::uuid,
            v_user_id,
            p_installation_id,
            (v_item ->> 'app_session_id')::uuid,
            v_occurred_at,
            v_item ->> 'event',
            v_properties ->> 'stage',
            coalesce(v_properties ->> 'reason_code', v_properties ->> 'outcome'),
            left(coalesce(nullif(v_item ->> 'app_version', ''), '0'), 32),
            v_platform
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

revoke all on function public.record_onboarding_events(uuid, jsonb) from public;
grant execute on function public.record_onboarding_events(uuid, jsonb) to anon, authenticated;

create or replace function public.founder_measurement_health(p_days integer default 7)
returns jsonb
language plpgsql
stable
security definer
set search_path = 'public', 'auth'
as $$
declare
    v_excluded uuid[] := public._excluded_user_ids();
    v_since timestamptz := now() - make_interval(days => greatest(1, least(p_days, 90)));
begin
    perform public._assert_founder();
    return jsonb_build_object(
        'window_days', greatest(1, least(p_days, 90)),
        'freshness', jsonb_build_object(
            'product_events', (
                select max(received_at) from public.product_events pe
                where pe.user_id <> all(v_excluded)
            ),
            'onboarding_events', (
                select max(created_at) from public.onboarding_events oe
                where oe.user_id is null or oe.user_id <> all(v_excluded)
            ),
            'acquisition_touches', (select max(created_at) from public.acquisition_touches),
            'ga_outbox_sent', (select max(sent_at) from public.google_conversion_outbox),
            'google_ads_sync', (select max(synced_at) from public.google_ads_campaign_daily)
        ),
        'rejected_events', (
            select count(*) from public.product_event_rejections r
            where r.received_at >= v_since
              and (r.user_id is null or r.user_id <> all(v_excluded))
        ),
        'rejected_events_excluded', (
            select count(*) from public.product_event_rejections r
            where r.received_at >= v_since and r.user_id = any(v_excluded)
        ),
        'rejection_breakdown', coalesce((
            select jsonb_agg(
                jsonb_build_object(
                    'reason_code', reason_code,
                    'event', event,
                    'platform', platform,
                    'count', event_count,
                    'last_seen', last_seen
                )
                order by event_count desc, reason_code
            )
            from (
                select r.reason_code, r.event, r.platform,
                       count(*) as event_count, max(r.received_at) as last_seen
                from public.product_event_rejections r
                where r.received_at >= v_since
                  and (r.user_id is null or r.user_id <> all(v_excluded))
                group by r.reason_code, r.event, r.platform
            ) rows
        ), '[]'::jsonb),
        'product_events', (
            select count(*) from public.product_events pe
            where pe.received_at >= v_since and pe.user_id <> all(v_excluded)
        ),
        'platform_coverage', coalesce((
            select jsonb_object_agg(platform, count)
            from (
                select pe.platform, count(*) as count
                from public.product_events pe
                where pe.received_at >= v_since and pe.user_id <> all(v_excluded)
                group by pe.platform
            ) rows
        ), '{}'::jsonb),
        'version_coverage_pct', (
            select case when count(*) = 0 then null
                        else round(count(*) filter (where app_version <> '0') * 100.0 / count(*), 1) end
            from public.product_events pe
            where pe.received_at >= v_since and pe.user_id <> all(v_excluded)
        ),
        'ios_consent', jsonb_build_object(
            'granted', (
                select count(*) from public.onboarding_events oe
                where oe.occurred_at >= v_since and oe.platform = 'ios'
                  and oe.event = 'analytics_consent_resolved' and oe.detail = 'granted'
                  and (oe.user_id is null or oe.user_id <> all(v_excluded))
            ),
            'declined_network_events', 0
        ),
        'attribution_coverage_pct', (
            select case when count(*) = 0 then null
                        else round(count(ua.last_touch_id) * 100.0 / count(*), 1) end
            from auth.users u
            left join public.user_acquisition ua on ua.user_id = u.id
            where u.created_at >= v_since and u.id <> all(v_excluded)
        ),
        'ga_outbox_pending', (
            select count(*) from public.google_conversion_outbox
            where status in ('pending', 'failed')
        ),
        'ga_outbox_oldest_pending', (
            select min(created_at) from public.google_conversion_outbox
            where status in ('pending', 'failed')
        ),
        'generated_at', now()
    );
end;
$$;

revoke all on function public.founder_measurement_health(integer) from public, anon;
grant execute on function public.founder_measurement_health(integer) to authenticated;
