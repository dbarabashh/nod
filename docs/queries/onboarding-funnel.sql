-- Onboarding funnel: signup → setup screens → permissions → first meeting.
--
-- Only meaningful for users who signed up on a build shipping
-- `OnboardingTelemetry` (Nod/Features/Onboarding/OnboardingTelemetry.swift).
-- Accounts created before that have no `onboarding_events` rows at all and read
-- as "stuck right after sign-in" — set `since` below to the release date.
--
-- Paste into the Supabase SQL editor. Three independent queries.

-- ============================================================
-- 1. The funnel
-- ============================================================
with params as (
    select now() - interval '30 days' as since
),
cohort as (
    select u.id
    from auth.users u, params p
    where u.created_at >= p.since
      and u.email not like '%@hellonod.app'
),
ev as (
    select e.user_id, e.event, e.step, e.detail
    from public.onboarding_events e
    join cohort c on c.id = e.user_id
),
stages as (
    select 1 as ord, 'signed up' as stage,
           (select count(*) from cohort) as users
    union all
    select 2, 'app installed + signed in',
           (select count(distinct d.user_id) from public.user_devices d join cohort c on c.id = d.user_id)
    union all
    select 3, 'saw welcome',
           (select count(distinct user_id) from ev where event = 'step_shown' and step = 'welcome')
    union all
    select 4, 'saw profile',
           (select count(distinct user_id) from ev where event = 'step_shown' and step = 'profile')
    union all
    select 5, 'saw permissions',
           (select count(distinct user_id) from ev where event = 'step_shown' and step = 'permissions')
    union all
    select 6, 'granted microphone',
           (select count(distinct user_id) from ev where event = 'permission_granted' and detail = 'microphone')
    union all
    select 7, 'granted screen recording',
           (select count(distinct user_id) from ev where event = 'permission_granted' and detail = 'screen_recording')
    union all
    select 8, 'saw tutorial',
           (select count(distinct user_id) from ev where event = 'step_shown' and step = 'tutorial')
    union all
    select 9, 'finished onboarding',
           (select count(distinct user_id) from ev where event = 'onboarding_completed')
    union all
    select 10, 'pressed Record (consent)',
           (select count(distinct a.user_id) from public.consent_acknowledgements a join cohort c on c.id = a.user_id)
    union all
    select 11, 'has a meeting',
           (select count(distinct m.user_id) from public.meetings m join cohort c on c.id = m.user_id)
)
select
    ord,
    stage,
    users,
    round(100.0 * users / nullif(max(users) over (), 0)) as pct_of_signups,
    users - lag(users) over (order by ord) as lost_here
from stages
order by ord;

-- ============================================================
-- 2. Where each user stopped — the list to email
-- ============================================================
with params as (
    select now() - interval '30 days' as since
),
last_event as (
    select distinct on (e.user_id)
        e.user_id, e.event, e.step, e.detail, e.created_at, e.app_version
    from public.onboarding_events e
    order by e.user_id, e.created_at desc
)
select
    u.email,
    u.created_at::date                                        as signup,
    s.trial_ends_at::date                                     as trial_ends,
    coalesce(le.event, 'no onboarding events')                as last_event,
    le.step                                                   as last_step,
    le.detail,
    le.created_at                                             as last_event_at,
    (select count(*) from public.meetings m where m.user_id = u.id) as meetings,
    (a.user_id is not null)                                   as pressed_record
from auth.users u
cross join params p
left join last_event le on le.user_id = u.id
left join public.subscriptions s on s.user_id = u.id
left join lateral (
    select user_id from public.consent_acknowledgements where user_id = u.id limit 1
) a on true
where u.created_at >= p.since
  and u.email not like '%@hellonod.app'
  and not exists (select 1 from public.meetings m where m.user_id = u.id)
order by u.created_at desc;

-- ============================================================
-- 3. Permission + relaunch diagnostics
-- ============================================================
select
    event,
    coalesce(detail, '—')            as detail,
    count(*)                         as events,
    count(distinct user_id)          as users,
    max(created_at)                  as last_seen
from public.onboarding_events
where event <> 'step_shown'
group by event, detail
order by users desc, event;
