update public.app_config
set platform = 'macos'
where platform is null or platform = '';
alter table public.app_config drop constraint app_config_singleton;
alter table public.app_config drop constraint app_config_pkey;
alter table public.app_config drop column singleton;
alter table public.app_config add column operation_required_build integer;
alter table public.app_config
    add constraint app_config_platform_check check (platform in ('macos', 'ios'));
alter table public.app_config add primary key (platform);
insert into public.app_config (
    platform,
    minimum_build,
    recommended_build,
    update_message,
    operation_required_build
) values ('ios', 0, 0, null, 1)
on conflict (platform) do nothing;
create table public.user_client_versions (
    user_id       uuid        not null references auth.users(id) on delete cascade,
    platform      text        not null check (platform in ('macos', 'ios')),
    app_build     integer     not null,
    app_version   text,
    os_version    text,
    last_seen_at  timestamptz not null default now(),
    primary key (user_id, platform)
);
alter table public.user_client_versions enable row level security;
create policy "users read own client versions"
    on public.user_client_versions
    for select
    to authenticated
    using ((select auth.uid()) = user_id);
insert into public.user_client_versions (
    user_id,
    platform,
    app_build,
    app_version,
    os_version,
    last_seen_at
)
select
    user_id,
    'macos',
    app_build,
    app_version,
    os_version,
    coalesce(last_seen_at, now())
from public.profiles
where app_build is not null
on conflict (user_id, platform) do nothing;
update public.plans
set limits = limits || '{"ios_companions": 1}'::jsonb;
alter table public.meetings
    add column self_speaker integer check (self_speaker is null or self_speaker >= 0);
alter table public.meeting_transcripts
    drop constraint meeting_transcripts_source_check;
alter table public.meeting_transcripts
    add constraint meeting_transcripts_source_check
    check (source in ('me', 'them', 'room'));
alter table public.profiles
    add column output_language text check (output_language is null or output_language ~ '^[a-z]{2}$');
alter table public.onboarding_events
    add column platform text not null default 'macos'
    check (platform in ('macos', 'ios'));
create or replace function public.snapshot_stt_cost(
    p_month date default (date_trunc('month', now() at time zone 'utc') - interval '1 month')::date
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    cfg jsonb;
begin
    select stt_rates into cfg from public.app_config where platform = 'macos';
    if cfg is null then
        raise notice 'snapshot_stt_cost: app_config.stt_rates is null — nothing recorded for %', p_month;
        return;
    end if;

    insert into public.stt_cost_reconciliation
        (period_month, provider, est_requests, est_billed_hours, est_cost_usd)
    select
        p_month,
        s.prov,
        count(*),
        round(sum(s.billed_seconds) / 3600.0, 3),
        round(sum(s.billed_seconds / 3600.0 * s.rate), 4)
    from (
        select
            p.prov,
            greatest(e.audio_seconds, coalesce((cfg -> p.prov ->> 'min_billed_seconds')::numeric, 0)) as billed_seconds,
            coalesce(
                (cfg -> p.prov -> 'models' ->> p.model_id)::numeric,
                (cfg -> p.prov ->> 'default')::numeric
            ) as rate
        from public.usage_events e
        cross join lateral (
            select
                case when e.model like '%:%' then split_part(e.model, ':', 1) else 'groq' end as prov,
                case when e.model like '%:%' then substring(e.model from position(':' in e.model) + 1) else e.model end as model_id
        ) p
        where e.kind = 'transcribe'
          and e.status between 200 and 299
          and e.audio_seconds > 0
          and e.created_at >= p_month
          and e.created_at < (p_month + interval '1 month')
    ) s
    where s.rate is not null
    group by s.prov
    on conflict (period_month, provider) do update
        set est_requests = excluded.est_requests,
            est_billed_hours = excluded.est_billed_hours,
            est_cost_usd = excluded.est_cost_usd;
end;
$$;
create or replace function public.claim_device(
    p_user_id uuid,
    p_device_id text,
    p_device_name text,
    p_platform text,
    p_ttl_seconds integer
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_platform text;
    v_limit    integer;
    v_active   integer;
    v_exists   boolean;
begin
    v_platform := case when p_platform = 'ios' then 'ios' else 'macos' end;
    perform pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user_id::text, 0));

    delete from public.user_devices
    where user_id = p_user_id
      and device_id <> p_device_id
      and last_seen_at < now() - pg_catalog.make_interval(secs => p_ttl_seconds);

    select greatest(1, coalesce(
        case
            when v_platform = 'ios' then (s.limit_overrides->>'ios_companions')::int
            else (s.limit_overrides->>'devices')::int
        end,
        case
            when v_platform = 'ios' then (pl.limits->>'ios_companions')::int
            else (pl.limits->>'devices')::int
        end,
        1
    ))
    into v_limit
    from public.subscriptions s
    join public.plans pl on pl.plan = s.plan
    where s.user_id = p_user_id;
    if v_limit is null then
        v_limit := 1;
    end if;

    select exists(
        select 1 from public.user_devices
        where user_id = p_user_id and device_id = p_device_id
    ) into v_exists;

    if v_exists then
        update public.user_devices
        set last_seen_at = now(),
            device_name = coalesce(p_device_name, device_name),
            platform = v_platform
        where user_id = p_user_id and device_id = p_device_id;
        return true;
    end if;

    select count(*) into v_active
    from public.user_devices
    where user_id = p_user_id and platform = v_platform;

    if v_active >= v_limit then
        return false;
    end if;

    insert into public.user_devices (user_id, device_id, device_name, platform)
    values (p_user_id, p_device_id, p_device_name, v_platform);
    return true;
end;
$$;
revoke all on function public.claim_device(uuid, text, text, text, integer)
    from public, anon, authenticated;
grant execute on function public.claim_device(uuid, text, text, text, integer)
    to service_role;
