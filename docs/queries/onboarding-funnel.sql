-- Onboarding funnel: signup → setup screens → permissions → first meeting.
--
-- Only meaningful for users who signed up on a build shipping
-- `OnboardingTelemetry` (Nod/Features/Onboarding/OnboardingTelemetry.swift).
-- Accounts created before that have no `onboarding_events` rows at all and read
-- as "stuck right after sign-in" — set `since` below to the release date.
--
-- Screen Recording never reports a grant from the process that asked — macOS
-- only hands the entry to a fresh one. Builds before `permission_pending_relaunch`
-- logged `permission_denied` on faith, so every one of those rows means "asked,
-- answer unknown", not "refused". Read stage 8 accordingly on older cohorts.
--
-- Paste into the Supabase SQL editor. Four independent queries.

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
    -- Order follows the shipped flow: welcome → calendar → permissions →
    -- profile → consent. It changed in 1.4, and cohorts that straddle the
    -- release mix both orders — read `lost_here` across that boundary with care.
    select 4, 'saw calendar',
           (select count(distinct user_id) from ev where event = 'step_shown' and step = 'calendar')
    union all
    select 5, 'saw permissions',
           (select count(distinct user_id) from ev where event = 'step_shown' and step = 'permissions')
    union all
    select 6, 'granted microphone',
           (select count(distinct user_id) from ev where event = 'permission_granted' and detail = 'microphone')
    union all
    select 7, 'answered screen recording',
           (select count(distinct user_id) from ev
             where detail = 'screen_recording'
               and event in ('permission_granted', 'permission_pending_relaunch'))
    union all
    select 8, 'saw profile',
           (select count(distinct user_id) from ev where event = 'step_shown' and step = 'profile')
    union all
    -- Pressed Continue, which the step allows with every field blank. For who
    -- actually answered, see query 4's "— unanswered" bucket.
    select 9, 'passed profile',
           (select count(distinct user_id) from ev where event = 'profile_completed')
    union all
    select 10, 'finished onboarding',
           (select count(distinct user_id) from ev where event = 'onboarding_completed')
    union all
    select 11, 'pressed Record (consent)',
           (select count(distinct a.user_id) from public.consent_acknowledgements a join cohort c on c.id = a.user_id)
    union all
    select 12, 'has a meeting',
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

-- ============================================================
-- 4. Who signs up, and does the role predict whether they stick
-- ============================================================
-- `profiles.role` / `profiles.heard_from` are answered once in onboarding and
-- both are optional, so "unanswered" is a real and interesting bucket.
with params as (
    select now() - interval '90 days' as since
),
cohort as (
    select u.id
    from auth.users u, params p
    where u.created_at >= p.since
      and u.email not like '%@hellonod.app'
)
select
    coalesce(p.role, '— unanswered')                              as role,
    count(*)                                                      as signups,
    count(*) filter (where m.meetings > 0)                        as recorded,
    round(100.0 * count(*) filter (where m.meetings > 0)
          / nullif(count(*), 0))                                  as pct_recorded,
    count(*) filter (where m.meetings >= 5)                       as five_plus
from cohort c
join public.profiles p on p.user_id = c.id
left join lateral (
    select count(*) as meetings from public.meetings mm where mm.user_id = c.id
) m on true
group by 1
order by signups desc;

-- Acquisition channel, same shape.
with params as (
    select now() - interval '90 days' as since
),
cohort as (
    select u.id
    from auth.users u, params p
    where u.created_at >= p.since
      and u.email not like '%@hellonod.app'
)
select
    coalesce(p.heard_from, '— unanswered') as channel,
    count(*)                               as signups
from cohort c
join public.profiles p on p.user_id = c.id
group by 1
order by signups desc;
