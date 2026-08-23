begin;

alter table public.acquisition_touches
    drop constraint acquisition_touches_event_check,
    drop constraint acquisition_touches_outcome_check,
    add constraint acquisition_touches_event_check check (event in (
        'page_view', 'download_click', 'get_nod_email_link', 'plan_select',
        'demo_booking_click', 'demo_interest_click', 'demo_booking_link_click',
        'contact_email_click', 'demo_booked', 'invite_open_app', 'invite_download',
        'referral_open_app'
    )),
    add constraint acquisition_touches_outcome_check check (outcome is null or outcome in (
        'viewed', 'download', 'redirect_to_get_nod', 'email_link',
        'booking_click', 'interest_click', 'booking_link_click', 'email_click',
        'confirmation_redirect', 'open_app'
    ));

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
        'demo_booking_click', 'demo_interest_click', 'demo_booking_link_click',
        'contact_email_click', 'demo_booked', 'invite_open_app', 'invite_download',
        'referral_open_app'
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

create or replace function public.founder_acquisition_attribution(p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
    v_excluded uuid[] := public._excluded_user_ids();
    v_window_days integer := greatest(1, least(p_days, 365));
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
           and u.created_at >= now() - make_interval(days => v_window_days)
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
    eligible_touches as (
        select t.*
          from public.acquisition_touches t
         where t.occurred_at >= now() - make_interval(days => v_window_days)
           and not exists (
               select 1 from public.acquisition_consent_revocations r
                where r.visitor_id = t.visitor_id
           )
    ),
    touch_metrics as (
        select
            coalesce(t.utm_campaign_id, t.utm_campaign, '(unassigned)') as campaign_key,
            max(coalesce(t.utm_campaign, '(unassigned)')) as campaign_name,
            max(coalesce(t.utm_source, 'direct')) as source,
            max(coalesce(t.utm_medium, '(none)')) as medium,
            count(distinct t.session_id) filter (where t.event = 'page_view') as sessions,
            count(*) filter (where t.event in ('download_click', 'invite_download')) as downloads,
            count(*) filter (
                where t.event in ('download_click', 'invite_download')
                  and t.platform = 'macos'
                  and t.outcome = 'download'
            ) as qualified_mac_downloads
          from eligible_touches t
         group by coalesce(t.utm_campaign_id, t.utm_campaign, '(unassigned)')
    ),
    lead_totals as (
        select
            count(*) filter (where event = 'demo_interest_click') as interest_clicks,
            count(*) filter (where event in ('demo_booking_click', 'demo_booking_link_click')) as booking_link_clicks,
            count(*) filter (where event = 'demo_booking_click') as legacy_booking_clicks,
            count(*) filter (where event = 'demo_booking_link_click') as current_booking_link_clicks,
            count(*) filter (where event = 'contact_email_click') as contact_email_clicks,
            count(*) filter (
                where event = 'demo_booked' and outcome = 'confirmation_redirect'
            ) as calendly_redirect_confirmations_unverified
          from eligible_touches
    ),
    lead_daily as (
        select
            s.day,
            count(t.id) filter (where t.event = 'demo_interest_click') as interest_clicks,
            count(t.id) filter (where t.event in ('demo_booking_click', 'demo_booking_link_click')) as booking_link_clicks,
            count(t.id) filter (where t.event = 'demo_booking_click') as legacy_booking_clicks,
            count(t.id) filter (where t.event = 'demo_booking_link_click') as current_booking_link_clicks,
            count(t.id) filter (where t.event = 'contact_email_click') as contact_email_clicks,
            count(t.id) filter (
                where t.event = 'demo_booked' and t.outcome = 'confirmation_redirect'
            ) as calendly_redirect_confirmations_unverified
          from generate_series(
              current_date - (v_window_days - 1),
              current_date,
              interval '1 day'
          ) as s(day)
          left join eligible_touches t on t.occurred_at::date = s.day::date
         group by s.day
         order by s.day
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
         where d.day >= current_date - v_window_days + 1
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
            coalesce(t.qualified_mac_downloads, 0) as qualified_mac_downloads,
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
        'window_days', v_window_days,
        'eligible_signups', (select count(*) from eligible_users),
        'attributed_signups', (select count(*) from eligible_users where last_touch_id is not null),
        'coverage_pct', (
            select case when count(*) = 0 then 0
                else round(count(last_touch_id) * 100.0 / count(*), 1)
            end
            from eligible_users
        ),
        'qualified_mac_downloads', coalesce((
            select sum(qualified_mac_downloads) from touch_metrics
        ), 0),
        'lead_funnel', jsonb_build_object(
            'totals', (select to_jsonb(lead_totals) from lead_totals),
            'daily', coalesce((
                select jsonb_agg(to_jsonb(lead_daily) order by day) from lead_daily
            ), '[]'::jsonb)
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
                     and m.created_at >= now() - make_interval(days => v_window_days)
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

revoke all on function public.founder_acquisition_attribution(integer) from public, anon;
grant execute on function public.founder_acquisition_attribution(integer) to authenticated;

commit;
