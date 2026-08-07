create table public.acquisition_touches (
    id                uuid primary key default gen_random_uuid(),
    visitor_id        uuid not null,
    session_id        uuid not null,
    occurred_at       timestamptz not null default now(),
    event              text not null check (event in (
        'page_view',
        'download_click',
        'get_nod_email_link',
        'plan_select',
        'demo_booking_click',
        'invite_open_app',
        'invite_download',
        'referral_open_app',
        'checkout_start',
        'purchase'
    )),
    page_path          text not null,
    page_group         text not null,
    placement          text,
    referrer_host      text,
    utm_source         text,
    utm_medium         text,
    utm_campaign       text,
    utm_campaign_id    text,
    utm_term           text,
    utm_content        text,
    gclid              text,
    gbraid             text,
    wbraid             text,
    ga_client_id       text,
    consent_version    text not null,
    created_at         timestamptz not null default now()
);

create index acquisition_touches_visitor_time_idx
    on public.acquisition_touches (visitor_id, occurred_at desc);

create index acquisition_touches_campaign_time_idx
    on public.acquisition_touches (utm_campaign_id, occurred_at desc)
    where utm_campaign_id is not null;

alter table public.acquisition_touches enable row level security;

create table public.acquisition_auth_flows (
    relay_id       uuid primary key,
    visitor_id     uuid not null,
    created_at     timestamptz not null default now(),
    expires_at     timestamptz not null default (now() + interval '24 hours'),
    claimed_by     uuid references auth.users(id) on delete cascade,
    claimed_at     timestamptz,
    check (expires_at > created_at)
);

create index acquisition_auth_flows_visitor_idx
    on public.acquisition_auth_flows (visitor_id, created_at desc);

alter table public.acquisition_auth_flows enable row level security;

create table public.acquisition_consent_revocations (
    visitor_id     uuid primary key,
    revoked_at     timestamptz not null default now()
);

alter table public.acquisition_consent_revocations enable row level security;

create table public.user_acquisition (
    user_id             uuid primary key references auth.users(id) on delete cascade,
    first_touch_id      uuid references public.acquisition_touches(id) on delete set null,
    last_touch_id       uuid references public.acquisition_touches(id) on delete set null,
    attribution_model   text not null default 'last_non_direct_90d',
    coverage_status     text not null check (coverage_status in ('attributed', 'no_eligible_touch')),
    claimed_at          timestamptz not null default now()
);

alter table public.user_acquisition enable row level security;

create policy "users read own acquisition"
    on public.user_acquisition
    for select
    to authenticated
    using ((select auth.uid()) = user_id);

create table public.google_conversion_outbox (
    id              uuid primary key default gen_random_uuid(),
    user_id         uuid not null references auth.users(id) on delete cascade,
    event            text not null check (event in ('trial_started', 'activated', 'subscription_paid')),
    occurred_at      timestamptz not null,
    touch_id         uuid references public.acquisition_touches(id) on delete set null,
    ga_client_id     text,
    value            numeric(12, 2),
    currency         text check (currency is null or currency ~ '^[A-Z]{3}$'),
    status           text not null default 'pending' check (status in ('pending', 'sent', 'failed', 'suppressed')),
    attempt_count    integer not null default 0,
    last_attempt_at  timestamptz,
    last_error       text,
    sent_at          timestamptz,
    created_at       timestamptz not null default now(),
    unique (user_id, event)
);

create index google_conversion_outbox_pending_idx
    on public.google_conversion_outbox (created_at)
    where status in ('pending', 'failed');

alter table public.google_conversion_outbox enable row level security;

create table public.google_ads_campaign_daily (
    day               date not null,
    customer_id       text not null,
    campaign_id       text not null,
    campaign_name     text not null,
    currency          text not null check (currency ~ '^[A-Z]{3}$'),
    impressions       bigint not null default 0 check (impressions >= 0),
    clicks            bigint not null default 0 check (clicks >= 0),
    cost_micros       bigint not null default 0 check (cost_micros >= 0),
    synced_at         timestamptz not null default now(),
    primary key (day, customer_id, campaign_id)
);

create index google_ads_campaign_daily_campaign_idx
    on public.google_ads_campaign_daily (campaign_id, day desc);

alter table public.google_ads_campaign_daily enable row level security;

alter table public.meetings
    add column source_platform text
    check (source_platform is null or source_platform in ('macos', 'ios'));

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
    v_page_path text := left(coalesce(nullif(p_payload ->> 'page_path', ''), '/'), 240);
    v_page_group text := left(coalesce(nullif(p_payload ->> 'page_group', ''), 'unknown'), 120);
begin
    if p_payload ->> 'consent' <> 'granted' then
        raise exception 'analytics consent required' using errcode = '22023';
    end if;

    delete from public.acquisition_consent_revocations
     where visitor_id = v_visitor_id;

    insert into public.acquisition_touches (
        id,
        visitor_id,
        session_id,
        occurred_at,
        event,
        page_path,
        page_group,
        placement,
        referrer_host,
        utm_source,
        utm_medium,
        utm_campaign,
        utm_campaign_id,
        utm_term,
        utm_content,
        gclid,
        gbraid,
        wbraid,
        ga_client_id,
        consent_version
    ) values (
        v_id,
        v_visitor_id,
        (p_payload ->> 'session_id')::uuid,
        now(),
        v_event,
        v_page_path,
        v_page_group,
        left(nullif(p_payload ->> 'placement', ''), 80),
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
    )
    on conflict (id) do nothing;

    return v_id;
end;
$$;

create or replace function public.revoke_acquisition_consent(p_visitor_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.acquisition_consent_revocations (visitor_id, revoked_at)
    values (p_visitor_id, now())
    on conflict (visitor_id) do update set revoked_at = excluded.revoked_at;

    update public.google_conversion_outbox o
       set status = 'suppressed',
           last_error = 'analytics consent withdrawn'
      from public.acquisition_touches t
     where o.touch_id = t.id
       and t.visitor_id = p_visitor_id
       and o.status in ('pending', 'failed');

    update public.user_acquisition ua
       set first_touch_id = null,
           last_touch_id = null,
           coverage_status = 'no_eligible_touch'
     where exists (
         select 1
           from public.acquisition_touches t
          where t.visitor_id = p_visitor_id
            and t.id in (ua.first_touch_id, ua.last_touch_id)
     );

    delete from public.acquisition_touches
     where visitor_id = p_visitor_id;
end;
$$;

create or replace function public.attach_acquisition_flow(
    p_relay_id uuid,
    p_visitor_id uuid,
    p_ga_client_id text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
    if p_ga_client_id is not null then
        update public.acquisition_touches
           set ga_client_id = left(p_ga_client_id, 120)
         where id = (
             select id
               from public.acquisition_touches
              where visitor_id = p_visitor_id
              order by occurred_at desc
              limit 1
         )
           and ga_client_id is null;
    end if;

    insert into public.acquisition_auth_flows (relay_id, visitor_id)
    values (p_relay_id, p_visitor_id)
    on conflict (relay_id) do nothing;

    return found;
end;
$$;

create or replace function public.claim_acquisition_flow(p_relay_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := auth.uid();
    v_visitor_id uuid;
    v_signup_at timestamptz;
    v_first_touch_id uuid;
    v_last_touch_id uuid;
    v_ga_client_id text;
begin
    if v_user_id is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    select visitor_id
      into v_visitor_id
      from public.acquisition_auth_flows
     where relay_id = p_relay_id
       and expires_at > now()
       and (claimed_by is null or claimed_by = v_user_id)
     for update;

    if v_visitor_id is null then
        return jsonb_build_object('status', 'missing_or_expired');
    end if;

    select created_at into v_signup_at from auth.users where id = v_user_id;

    select id
      into v_first_touch_id
      from public.acquisition_touches
     where visitor_id = v_visitor_id
       and not exists (
           select 1 from public.acquisition_consent_revocations r
            where r.visitor_id = v_visitor_id
       )
       and occurred_at between v_signup_at - interval '90 days' and v_signup_at + interval '1 hour'
     order by occurred_at asc
     limit 1;

    select id, ga_client_id
      into v_last_touch_id, v_ga_client_id
      from public.acquisition_touches
     where visitor_id = v_visitor_id
       and not exists (
           select 1 from public.acquisition_consent_revocations r
            where r.visitor_id = v_visitor_id
       )
       and occurred_at between v_signup_at - interval '90 days' and v_signup_at + interval '1 hour'
     order by (
         utm_source is not null
         or gclid is not null
         or gbraid is not null
         or wbraid is not null
         or (referrer_host is not null and referrer_host <> 'hellonod.app')
     ) desc, occurred_at desc
     limit 1;

    update public.acquisition_auth_flows
       set claimed_by = v_user_id,
           claimed_at = now()
     where relay_id = p_relay_id;

    insert into public.user_acquisition (
        user_id,
        first_touch_id,
        last_touch_id,
        coverage_status
    ) values (
        v_user_id,
        v_first_touch_id,
        v_last_touch_id,
        case when v_last_touch_id is null then 'no_eligible_touch' else 'attributed' end
    )
    on conflict (user_id) do nothing;

    if v_last_touch_id is not null then
        insert into public.google_conversion_outbox (
            user_id,
            event,
            occurred_at,
            touch_id,
            ga_client_id
        ) values (
            v_user_id,
            'trial_started',
            v_signup_at,
            v_last_touch_id,
            v_ga_client_id
        )
        on conflict (user_id, event) do nothing;
    end if;

    return jsonb_build_object(
        'status', case when v_last_touch_id is null then 'no_eligible_touch' else 'attributed' end,
        'first_touch_id', v_first_touch_id,
        'last_touch_id', v_last_touch_id
    );
end;
$$;

create or replace function public.enqueue_activation_conversion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_signup_at timestamptz;
    v_touch_id uuid;
    v_ga_client_id text;
begin
    if new.ended_at is null then
        return new;
    end if;

    select created_at into v_signup_at from auth.users where id = new.user_id;
    if new.ended_at > v_signup_at + interval '7 days' then
        return new;
    end if;

    select ua.last_touch_id, t.ga_client_id
      into v_touch_id, v_ga_client_id
      from public.user_acquisition ua
      left join public.acquisition_touches t on t.id = ua.last_touch_id
     where ua.user_id = new.user_id
       and ua.coverage_status = 'attributed';

    if exists (
        select 1
          from public.acquisition_touches t
          join public.acquisition_consent_revocations r on r.visitor_id = t.visitor_id
         where t.id = v_touch_id
    ) then
        return new;
    end if;

    if v_touch_id is not null then
        insert into public.google_conversion_outbox (
            user_id,
            event,
            occurred_at,
            touch_id,
            ga_client_id
        ) values (
            new.user_id,
            'activated',
            new.ended_at,
            v_touch_id,
            v_ga_client_id
        )
        on conflict (user_id, event) do nothing;
    end if;

    return new;
end;
$$;

create trigger on_meeting_insert_acquisition_conversion
    after insert on public.meetings
    for each row execute function public.enqueue_activation_conversion();

create trigger on_meeting_completed_acquisition_conversion
    after update of ended_at on public.meetings
    for each row execute function public.enqueue_activation_conversion();

create or replace function public.enqueue_paid_conversion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_touch_id uuid;
    v_ga_client_id text;
begin
    if new.converted_at is null
       or (tg_op = 'UPDATE' and old.converted_at is not null) then
        return new;
    end if;

    select ua.last_touch_id, t.ga_client_id
      into v_touch_id, v_ga_client_id
      from public.user_acquisition ua
      left join public.acquisition_touches t on t.id = ua.last_touch_id
     where ua.user_id = new.user_id
       and ua.coverage_status = 'attributed';

    if exists (
        select 1
          from public.acquisition_touches t
          join public.acquisition_consent_revocations r on r.visitor_id = t.visitor_id
         where t.id = v_touch_id
    ) then
        return new;
    end if;

    if v_touch_id is not null then
        insert into public.google_conversion_outbox (
            user_id,
            event,
            occurred_at,
            touch_id,
            ga_client_id
        ) values (
            new.user_id,
            'subscription_paid',
            new.converted_at,
            v_touch_id,
            v_ga_client_id
        )
        on conflict (user_id, event) do nothing;
    end if;

    return new;
end;
$$;

create trigger on_subscription_insert_paid_acquisition_conversion
    after insert on public.subscriptions
    for each row execute function public.enqueue_paid_conversion();

create trigger on_subscription_update_paid_acquisition_conversion
    after update of converted_at on public.subscriptions
    for each row execute function public.enqueue_paid_conversion();

create or replace function public.purge_expired_acquisition_analytics()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    delete from public.acquisition_auth_flows
     where expires_at < now() - interval '7 days';

    delete from public.google_conversion_outbox
     where created_at < now() - interval '400 days'
       and status in ('sent', 'suppressed');

    delete from public.user_acquisition
     where claimed_at < now() - interval '400 days';

    delete from public.acquisition_touches
     where occurred_at < now() - interval '400 days';

    delete from public.acquisition_consent_revocations r
     where r.revoked_at < now() - interval '400 days'
       and not exists (
           select 1 from public.acquisition_touches t
            where t.visitor_id = r.visitor_id
       );

    delete from public.google_ads_campaign_daily
     where day < current_date - 400;
end;
$$;

do $$
begin
    perform cron.schedule(
        'purge-expired-acquisition-analytics',
        '41 3 * * *',
        'select public.purge_expired_acquisition_analytics()'
    );
exception when others then
    raise notice 'acquisition analytics purge schedule unavailable: %', sqlerrm;
end $$;

create or replace function public.founder_acquisition_attribution(p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
    v_excluded uuid[] := public._excluded_user_ids();
    v_result jsonb;
begin
    perform public._assert_founder();

    with eligible_users as (
        select
            u.id,
            u.created_at,
            case when r.visitor_id is null then ua.last_touch_id end as last_touch_id
          from auth.users u
          left join public.user_acquisition ua on ua.user_id = u.id
          left join public.acquisition_touches attributed_touch on attributed_touch.id = ua.last_touch_id
          left join public.acquisition_consent_revocations r on r.visitor_id = attributed_touch.visitor_id
         where u.id <> all(v_excluded)
           and u.created_at >= now() - make_interval(days => greatest(1, least(p_days, 365)))
    ),
    attributed_users as (
        select
            eu.id,
            eu.created_at,
            coalesce(t.utm_campaign_id, t.utm_campaign, '(unassigned)') as campaign_key,
            coalesce(t.utm_campaign, '(unassigned)') as campaign_name,
            coalesce(t.utm_source, 'direct') as source,
            coalesce(t.utm_medium, '(none)') as medium
          from eligible_users eu
          join public.acquisition_touches t on t.id = eu.last_touch_id
    ),
    user_metrics as (
        select
            au.campaign_key,
            max(au.campaign_name) as campaign_name,
            max(au.source) as source,
            max(au.medium) as medium,
            count(*) as trials,
            count(*) filter (where exists (
                select 1 from public.meetings m
                 where m.user_id = au.id
                   and m.deleted_at is null
                   and m.ended_at <= au.created_at + interval '7 days'
            )) as activated,
            count(*) filter (where au.created_at <= now() - interval '14 days') as mature_trials,
            count(*) filter (where exists (
                select 1 from public.subscriptions s
                 where s.user_id = au.id and s.converted_at is not null
            )) as paid
          from attributed_users au
         group by au.campaign_key
    ),
    touch_metrics as (
        select
            coalesce(t.utm_campaign_id, t.utm_campaign, '(unassigned)') as campaign_key,
            max(coalesce(t.utm_campaign, '(unassigned)')) as campaign_name,
            max(coalesce(t.utm_source, 'direct')) as source,
            max(coalesce(t.utm_medium, '(none)')) as medium,
            count(distinct t.session_id) filter (where t.event = 'page_view') as sessions,
            count(*) filter (where t.event in ('download_click', 'invite_download')) as downloads
          from public.acquisition_touches t
         where t.occurred_at >= now() - make_interval(days => greatest(1, least(p_days, 365)))
           and not exists (
               select 1 from public.acquisition_consent_revocations r
                where r.visitor_id = t.visitor_id
           )
         group by coalesce(t.utm_campaign_id, t.utm_campaign, '(unassigned)')
    ),
    ad_metrics as (
        select
            d.campaign_id as campaign_key,
            max(d.campaign_name) as campaign_name,
            d.currency,
            sum(d.impressions) as impressions,
            sum(d.clicks) as clicks,
            sum(d.cost_micros) / 1000000.0 as spend
          from public.google_ads_campaign_daily d
         where d.day >= current_date - greatest(1, least(p_days, 365)) + 1
         group by d.campaign_id, d.currency
    ),
    keys as (
        select campaign_key from user_metrics
        union
        select campaign_key from touch_metrics
        union
        select campaign_key from ad_metrics
    ),
    campaign_rows as (
        select
            k.campaign_key as campaign_id,
            coalesce(a.campaign_name, u.campaign_name, t.campaign_name, '(unassigned)') as campaign_name,
            coalesce(u.source, t.source, 'google') as source,
            coalesce(u.medium, t.medium, 'cpc') as medium,
            a.currency,
            coalesce(a.impressions, 0) as impressions,
            coalesce(a.clicks, 0) as clicks,
            coalesce(a.spend, 0) as spend,
            coalesce(t.sessions, 0) as sessions,
            coalesce(t.downloads, 0) as downloads,
            coalesce(u.trials, 0) as trials,
            coalesce(u.activated, 0) as activated,
            coalesce(u.mature_trials, 0) as mature_trials,
            coalesce(u.paid, 0) as paid
          from keys k
          left join user_metrics u using (campaign_key)
          left join touch_metrics t using (campaign_key)
          left join ad_metrics a using (campaign_key)
    )
    select jsonb_build_object(
        'window_days', greatest(1, least(p_days, 365)),
        'eligible_signups', (select count(*) from eligible_users),
        'attributed_signups', (select count(*) from eligible_users where last_touch_id is not null),
        'coverage_pct', (
            select case when count(*) = 0 then 0
                else round(count(last_touch_id) * 100.0 / count(*), 1)
            end
            from eligible_users
        ),
        'platforms', coalesce((
            select jsonb_agg(to_jsonb(platform_rows) order by sessions desc)
              from (
                  select
                      coalesce(m.source_platform, 'unknown') as platform,
                      count(*) as sessions,
                      count(distinct m.user_id) as users
                    from public.meetings m
                   where m.deleted_at is null
                     and m.user_id <> all(v_excluded)
                     and m.created_at >= now() - make_interval(days => greatest(1, least(p_days, 365)))
                   group by coalesce(m.source_platform, 'unknown')
              ) platform_rows
        ), '[]'::jsonb),
        'campaigns', coalesce((
            select jsonb_agg(to_jsonb(campaign_rows) order by paid desc, trials desc, sessions desc)
            from campaign_rows
        ), '[]'::jsonb),
        'generated_at', now()
    ) into v_result;

    return v_result;
end;
$$;

revoke all on function public.record_acquisition_touch(jsonb) from public, authenticated;
grant execute on function public.record_acquisition_touch(jsonb) to anon;

revoke all on function public.revoke_acquisition_consent(uuid) from public, authenticated;
grant execute on function public.revoke_acquisition_consent(uuid) to anon;

revoke all on function public.attach_acquisition_flow(uuid, uuid, text) from public, authenticated;
grant execute on function public.attach_acquisition_flow(uuid, uuid, text) to anon;

revoke all on function public.claim_acquisition_flow(uuid) from public, anon;
grant execute on function public.claim_acquisition_flow(uuid) to authenticated;

revoke all on function public.founder_acquisition_attribution(integer) from public, anon;
grant execute on function public.founder_acquisition_attribution(integer) to authenticated;

revoke all on function public.enqueue_activation_conversion() from public, anon, authenticated;
revoke all on function public.enqueue_paid_conversion() from public, anon, authenticated;
revoke all on function public.purge_expired_acquisition_analytics() from public, anon, authenticated;
