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
           'home', 'library', 'quick_capture', 'live_activity', 'meeting_detail', 'ask', 'settings'
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
           'monthly', 'yearly', 'none', 'unknown'
       ));
$$;

alter table public.acquisition_touches
    drop constraint acquisition_touches_event_check,
    add constraint acquisition_touches_event_check check (event in (
        'page_view', 'download_click', 'get_nod_email_link', 'plan_select',
        'demo_booking_click', 'invite_open_app', 'invite_download', 'referral_open_app'
    )),
    add column content_locale text not null default 'en'
        check (content_locale ~ '^[a-z]{2}$'),
    add column platform text
        check (platform is null or platform in ('macos', 'ios', 'android', 'other')),
    add column outcome text
        check (outcome is null or outcome in (
            'viewed', 'download', 'redirect_to_get_nod', 'email_link',
            'booking_click', 'open_app'
        )),
    add column plan text
        check (plan is null or plan in ('starter', 'pro')),
    add column billing text
        check (billing is null or billing in ('monthly', 'yearly'));

create or replace function public.record_acquisition_touch(p_payload jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_id uuid := coalesce(nullif(p_payload ->> 'event_id', '')::uuid, gen_random_uuid());
    v_visitor_id uuid := (p_payload ->> 'visitor_id')::uuid;
    v_event text := p_payload ->> 'event';
begin
    if p_payload ->> 'consent' <> 'granted' then
        raise exception 'analytics consent required' using errcode = '22023';
    end if;
    if v_event not in (
        'page_view', 'download_click', 'get_nod_email_link', 'plan_select',
        'demo_booking_click', 'invite_open_app', 'invite_download', 'referral_open_app'
    ) then
        raise exception 'invalid acquisition event' using errcode = '22023';
    end if;

    delete from public.acquisition_consent_revocations
    where visitor_id = v_visitor_id;

    insert into public.acquisition_touches (
        id, visitor_id, session_id, occurred_at, event, page_path, page_group,
        content_locale, placement, platform, outcome, plan, billing,
        referrer_host, utm_source, utm_medium, utm_campaign, utm_campaign_id,
        utm_term, utm_content, gclid, gbraid, wbraid, ga_client_id, consent_version
    ) values (
        v_id,
        v_visitor_id,
        (p_payload ->> 'session_id')::uuid,
        now(),
        v_event,
        left(coalesce(nullif(p_payload ->> 'page_path', ''), '/'), 240),
        left(coalesce(nullif(p_payload ->> 'page_group', ''), 'unknown'), 120),
        case when p_payload ->> 'content_locale' ~ '^[a-z]{2}$'
             then p_payload ->> 'content_locale' else 'en' end,
        left(nullif(p_payload ->> 'placement', ''), 80),
        nullif(p_payload ->> 'platform', ''),
        nullif(p_payload ->> 'outcome', ''),
        nullif(p_payload ->> 'plan', ''),
        nullif(p_payload ->> 'billing', ''),
        left(nullif(p_payload ->> 'referrer_host', ''), 253),
        left(nullif(p_payload ->> 'utm_source', ''), 120),
        left(nullif(p_payload ->> 'utm_medium', ''), 120),
        left(nullif(p_payload ->> 'utm_campaign', ''), 200),
        left(nullif(p_payload ->> 'utm_campaign_id', ''), 120),
        left(nullif(p_payload ->> 'utm_term', ''), 200),
        left(nullif(p_payload ->> 'utm_content', ''), 200),
        left(nullif(p_payload ->> 'gclid', ''), 240),
        left(nullif(p_payload ->> 'gbraid', ''), 240),
        left(nullif(p_payload ->> 'wbraid', ''), 240),
        left(nullif(p_payload ->> 'ga_client_id', ''), 120),
        left(coalesce(nullif(p_payload ->> 'consent_version', ''), 'web-v1'), 40)
    ) on conflict (id) do nothing;

    return v_id;
end;
$$;

create table public.product_events (
    id              uuid primary key,
    user_id         uuid not null references auth.users(id) on delete cascade,
    occurred_at     timestamptz not null,
    received_at     timestamptz not null default now(),
    app_session_id  uuid,
    capture_id      uuid,
    event           text not null check (event in (
        'app_opened', 'capture_start_requested', 'capture_started', 'capture_stopped',
        'capture_failed', 'capture_discarded', 'summary_viewed', 'transcript_viewed',
        'action_items_viewed', 'content_copied', 'meeting_exported',
        'ai_action_completed', 'paywall_viewed', 'checkout_started'
    )),
    platform        text not null check (platform in ('macos', 'ios', 'server')),
    app_version     text not null check (app_version ~ '^[0-9A-Za-z.+-]{1,32}$'),
    properties      jsonb not null default '{}'::jsonb,
    check (public._valid_product_event_properties(properties)),
    check (platform = 'server' or app_session_id is not null)
);

create index product_events_user_time_idx
    on public.product_events (user_id, occurred_at desc);
create index product_events_event_time_idx
    on public.product_events (event, occurred_at desc);
create index product_events_capture_idx
    on public.product_events (capture_id, occurred_at)
    where capture_id is not null;

alter table public.product_events enable row level security;

create table public.product_event_rejections (
    id              bigint generated always as identity primary key,
    user_id         uuid references auth.users(id) on delete cascade,
    installation_id uuid,
    platform        text check (platform is null or platform in ('macos', 'ios')),
    reason_code     text not null check (reason_code in (
        'invalid_batch', 'invalid_event', 'invalid_identifier', 'invalid_properties',
        'invalid_timestamp', 'rate_limited'
    )),
    received_at     timestamptz not null default now()
);

create index product_event_rejections_time_idx
    on public.product_event_rejections (received_at desc);

alter table public.product_event_rejections enable row level security;

alter table public.onboarding_events
    alter column user_id drop not null,
    add column installation_id uuid,
    add column app_session_id uuid,
    add column occurred_at timestamptz,
    add constraint onboarding_event_owner_check
        check (user_id is not null or installation_id is not null);

update public.onboarding_events
set occurred_at = created_at
where occurred_at is null;

alter table public.onboarding_events
    alter column occurred_at set default now(),
    alter column occurred_at set not null;

create index onboarding_events_installation_time_idx
    on public.onboarding_events (installation_id, occurred_at desc)
    where installation_id is not null;

drop policy if exists "users insert own onboarding events" on public.onboarding_events;

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
        if coalesce(v_item ->> 'event', '') not in (
            'app_opened', 'capture_start_requested', 'capture_started', 'capture_stopped',
            'capture_failed', 'capture_discarded', 'summary_viewed', 'transcript_viewed',
            'action_items_viewed', 'content_copied', 'meeting_exported',
            'ai_action_completed', 'paywall_viewed'
        ) or coalesce(v_item ->> 'platform', '') not in ('macos', 'ios')
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

create or replace function public.record_onboarding_events(
    p_installation_id uuid,
    p_events jsonb
)
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
        if coalesce(v_item ->> 'id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
           or coalesce(v_item ->> 'app_session_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
            insert into public.product_event_rejections (user_id, installation_id, platform, reason_code)
            values (v_user_id, p_installation_id, case when v_platform in ('macos', 'ios') then v_platform end, 'invalid_identifier');
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
            insert into public.product_event_rejections (user_id, installation_id, platform, reason_code)
            values (v_user_id, p_installation_id, case when v_platform in ('macos', 'ios') then v_platform end, 'invalid_event');
            v_rejected := v_rejected + 1;
            continue;
        end if;
        if not public._valid_product_event_properties(v_properties) then
            insert into public.product_event_rejections (user_id, installation_id, platform, reason_code)
            values (v_user_id, p_installation_id, v_platform, 'invalid_properties');
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
            insert into public.product_event_rejections (user_id, installation_id, platform, reason_code)
            values (v_user_id, p_installation_id, v_platform, 'invalid_timestamp');
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

create or replace function public.claim_onboarding_installation(p_installation_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := auth.uid();
    v_claimed integer;
begin
    if v_user_id is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    update public.onboarding_events
    set user_id = v_user_id
    where installation_id = p_installation_id
      and user_id is null
      and created_at >= now() - interval '30 days';
    get diagnostics v_claimed = row_count;
    return v_claimed;
end;
$$;

alter table public.meeting_shares
    add column id uuid not null default gen_random_uuid();
alter table public.meeting_shares
    add constraint meeting_shares_id_key unique (id);

create table public.share_product_events (
    id                  uuid primary key,
    share_id            uuid not null references public.meeting_shares(id) on delete cascade,
    browser_session_id  uuid not null,
    event               text not null check (event in ('share_viewed', 'share_ask_completed')),
    occurred_at         timestamptz not null default now(),
    received_at         timestamptz not null default now()
);

create unique index share_product_events_view_once_idx
    on public.share_product_events (share_id, browser_session_id, event)
    where event = 'share_viewed';
create index share_product_events_time_idx
    on public.share_product_events (occurred_at desc);

alter table public.share_product_events enable row level security;

create or replace function public.record_share_view(
    p_token uuid,
    p_event_id uuid,
    p_browser_session_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_share_id uuid;
begin
    select s.id into v_share_id
    from public.meeting_shares s
    join public.meetings m on m.id = s.meeting_id
    where s.token = p_token
      and s.revoked_at is null
      and m.deleted_at is null;
    if v_share_id is null then
        return false;
    end if;
    insert into public.share_product_events (id, share_id, browser_session_id, event)
    values (p_event_id, v_share_id, p_browser_session_id, 'share_viewed')
    on conflict do nothing;
    return true;
end;
$$;

create or replace function public.purge_product_analytics()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    delete from public.onboarding_events
    where user_id is null
      and created_at < now() - interval '30 days';
    delete from public.product_events
    where received_at < now() - interval '24 months';
    delete from public.product_event_rejections
    where received_at < now() - interval '90 days';
    delete from public.share_product_events
    where received_at < now() - interval '24 months';
end;
$$;

do $$
begin
    perform cron.schedule(
        'purge-product-analytics',
        '17 4 * * *',
        'select public.purge_product_analytics()'
    );
exception when others then
    raise notice 'product analytics purge schedule unavailable: %', sqlerrm;
end $$;

create or replace function public.founder_onboarding_activation(
    p_days integer default 30,
    p_platform text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
    v_excluded uuid[] := public._excluded_user_ids();
    v_since timestamptz := now() - make_interval(days => greatest(1, least(p_days, 365)));
    v_result jsonb;
begin
    perform public._assert_founder();
    select jsonb_build_object(
        'window_days', greatest(1, least(p_days, 365)),
        'platform', p_platform,
        'events', coalesce((
            select jsonb_agg(to_jsonb(rows) order by rows.count desc)
            from (
                select oe.event, oe.step as stage, count(*) as count,
                       count(distinct coalesce(oe.user_id::text, oe.installation_id::text)) as people
                from public.onboarding_events oe
                where oe.occurred_at >= v_since
                  and (p_platform is null or oe.platform = p_platform)
                  and (oe.user_id is null or oe.user_id <> all(v_excluded))
                group by oe.event, oe.step
            ) rows
        ), '[]'::jsonb),
        'activation', jsonb_build_object(
            'signups', (
                select count(*) from auth.users u
                where u.created_at >= v_since and u.id <> all(v_excluded)
                  and (p_platform is null or exists (
                      select 1 from public.user_client_versions cv
                      where cv.user_id = u.id and cv.platform = p_platform
                  ))
            ),
            'capture_started', (
                select count(distinct pe.user_id) from public.product_events pe
                where pe.occurred_at >= v_since and pe.event = 'capture_started'
                  and pe.user_id <> all(v_excluded)
                  and (p_platform is null or pe.platform = p_platform)
            ),
            'first_meeting', (
                select count(distinct m.user_id) from public.meetings m
                where m.ended_at >= v_since and m.deleted_at is null
                  and m.user_id <> all(v_excluded)
                  and (p_platform is null or m.source_platform = p_platform)
            ),
            'second_meeting_within_three_days', (
                select count(*)
                from (
                    select m.user_id, min(m.ended_at) as first_ended_at
                    from public.meetings m
                    where m.deleted_at is null and m.user_id <> all(v_excluded)
                      and m.ended_at is not null
                      and (p_platform is null or m.source_platform = p_platform)
                    group by m.user_id
                ) firsts
                where firsts.first_ended_at >= v_since
                  and (
                      select count(*)
                      from public.meetings m2
                      where m2.user_id = firsts.user_id
                        and m2.deleted_at is null
                        and m2.ended_at between firsts.first_ended_at
                            and firsts.first_ended_at + interval '3 days'
                        and (p_platform is null or m2.source_platform = p_platform)
                  ) >= 2
            )
        ),
        'generated_at', now()
    ) into v_result;
    return v_result;
end;
$$;

create or replace function public.founder_capture_reliability(
    p_days integer default 30,
    p_platform text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_excluded uuid[] := public._excluded_user_ids();
    v_since timestamptz := now() - make_interval(days => greatest(1, least(p_days, 365)));
begin
    perform public._assert_founder();
    return jsonb_build_object(
        'window_days', greatest(1, least(p_days, 365)),
        'platform', p_platform,
        'stages', coalesce((
            select jsonb_agg(to_jsonb(rows) order by rows.count desc)
            from (
                select pe.event,
                       coalesce(pe.properties ->> 'stage', 'unknown') as stage,
                       coalesce(pe.properties ->> 'reason_code', 'none') as reason_code,
                       coalesce(pe.properties ->> 'session_kind', 'unknown') as session_kind,
                       coalesce(pe.properties ->> 'entry_point', 'unknown') as entry_point,
                       pe.app_version,
                       count(*) as count,
                       count(distinct pe.capture_id) as captures
                from public.product_events pe
                where pe.occurred_at >= v_since
                  and pe.event in (
                      'capture_start_requested', 'capture_started', 'capture_stopped',
                      'capture_failed', 'capture_discarded'
                  )
                  and pe.user_id <> all(v_excluded)
                  and (p_platform is null or pe.platform = p_platform)
                group by pe.event, stage, reason_code, session_kind, entry_point, pe.app_version
            ) rows
        ), '[]'::jsonb),
        'persisted', (
            select count(*) from public.meetings m
            where m.ended_at >= v_since and m.deleted_at is null
              and m.user_id <> all(v_excluded)
              and (p_platform is null or m.source_platform = p_platform)
        ),
        'generated_at', now()
    );
end;
$$;

create or replace function public.founder_value_adoption(
    p_days integer default 30,
    p_platform text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_excluded uuid[] := public._excluded_user_ids();
    v_since timestamptz := now() - make_interval(days => greatest(1, least(p_days, 365)));
begin
    perform public._assert_founder();
    return jsonb_build_object(
        'window_days', greatest(1, least(p_days, 365)),
        'platform', p_platform,
        'events', coalesce((
            select jsonb_agg(to_jsonb(rows) order by rows.count desc)
            from (
                select pe.event,
                       coalesce(pe.properties ->> 'surface', 'unknown') as surface,
                       coalesce(pe.properties ->> 'content_type', 'unknown') as content_type,
                       coalesce(pe.properties ->> 'ai_feature', 'none') as ai_feature,
                       count(*) as count,
                       count(distinct pe.user_id) as users
                from public.product_events pe
                where pe.occurred_at >= v_since
                  and pe.event in (
                      'summary_viewed', 'transcript_viewed', 'action_items_viewed',
                      'content_copied', 'meeting_exported', 'ai_action_completed',
                      'paywall_viewed', 'checkout_started'
                  )
                  and pe.user_id <> all(v_excluded)
                  and (p_platform is null or pe.platform = p_platform or pe.platform = 'server')
                group by pe.event, surface, content_type, ai_feature
            ) rows
        ), '[]'::jsonb),
        'shares_created', (
            select count(*) from public.meeting_shares s
            where s.created_at >= v_since and s.created_by <> all(v_excluded)
        ),
        'share_views', (
            select count(*) from public.share_product_events e
            join public.meeting_shares s on s.id = e.share_id
            where e.occurred_at >= v_since and e.event = 'share_viewed'
              and s.created_by <> all(v_excluded)
        ),
        'share_asks', (
            select count(*) from public.share_product_events e
            join public.meeting_shares s on s.id = e.share_id
            where e.occurred_at >= v_since and e.event = 'share_ask_completed'
              and s.created_by <> all(v_excluded)
        ),
        'paid', (
            select count(*) from public.subscriptions s
            where s.converted_at >= v_since and s.user_id <> all(v_excluded)
        ),
        'generated_at', now()
    );
end;
$$;

create or replace function public.founder_measurement_health(p_days integer default 7)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
    v_excluded uuid[] := public._excluded_user_ids();
    v_since timestamptz := now() - make_interval(days => greatest(1, least(p_days, 90)));
begin
    perform public._assert_founder();
    return jsonb_build_object(
        'window_days', greatest(1, least(p_days, 90)),
        'freshness', jsonb_build_object(
            'product_events', (select max(received_at) from public.product_events),
            'onboarding_events', (select max(created_at) from public.onboarding_events),
            'acquisition_touches', (select max(created_at) from public.acquisition_touches),
            'ga_outbox_sent', (select max(sent_at) from public.google_conversion_outbox),
            'google_ads_sync', (select max(synced_at) from public.google_ads_campaign_daily)
        ),
        'rejected_events', (
            select count(*) from public.product_event_rejections where received_at >= v_since
        ),
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
            select case when count(*) = 0 then 0
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
            select case when count(*) = 0 then 0
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

revoke all on function public._valid_product_event_properties(jsonb) from public, anon, authenticated;
revoke all on function public.record_product_events(jsonb) from public, anon;
grant execute on function public.record_product_events(jsonb) to authenticated;
revoke all on function public.record_onboarding_events(uuid, jsonb) from public;
grant execute on function public.record_onboarding_events(uuid, jsonb) to anon, authenticated;
revoke all on function public.claim_onboarding_installation(uuid) from public, anon;
grant execute on function public.claim_onboarding_installation(uuid) to authenticated;
revoke all on function public.record_share_view(uuid, uuid, uuid) from public;
grant execute on function public.record_share_view(uuid, uuid, uuid) to anon, authenticated;
revoke all on function public.purge_product_analytics() from public, anon, authenticated;
revoke all on function public.founder_onboarding_activation(integer, text) from public, anon;
revoke all on function public.founder_capture_reliability(integer, text) from public, anon;
revoke all on function public.founder_value_adoption(integer, text) from public, anon;
revoke all on function public.founder_measurement_health(integer) from public, anon;
grant execute on function public.founder_onboarding_activation(integer, text) to authenticated;
grant execute on function public.founder_capture_reliability(integer, text) to authenticated;
grant execute on function public.founder_value_adoption(integer, text) to authenticated;
grant execute on function public.founder_measurement_health(integer) to authenticated;
