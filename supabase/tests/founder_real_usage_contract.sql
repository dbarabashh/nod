begin;

-- The welcome sample is not usage. A person whose only meeting is the seeded
-- one has not activated, has not retained, has not completed an action item,
-- and did not convert for Google. Stages are counted apart, retention only over
-- cohorts that have lived through the horizon.

set local role authenticated;
set local request.jwt.claims = '{"sub":"30000000-0000-4000-8000-000000000401","email":"vlad@hellonod.app","role":"authenticated"}';
create temp table before_stages as select public.founder_activation_stages(14) as r;
create temp table before_activation as select public.founder_activation(1, 7) as r;
create temp table before_funnel as select * from public.founder_activation_funnel();
create temp table before_overview as select public.founder_overview(1, 7) as r;
create temp table before_retention as select * from public.founder_retention_cohorts(8);
create temp table before_metrics as select public.founder_metrics() as r;
create temp table before_onboarding as select public.founder_onboarding_activation(400, null) as r;
reset role;

insert into auth.users (id, email, created_at, updated_at)
values
    ('30000000-0000-4000-8000-000000000401', 'vlad@hellonod.app', now() - interval '200 days', now()),
    ('30000000-0000-4000-8000-000000000411', 'sample-only@example.invalid', now() - interval '20 days', now()),
    ('30000000-0000-4000-8000-000000000412', 'real-user@example.invalid', now() - interval '20 days', now()),
    ('30000000-0000-4000-8000-000000000413', 'zero-duration@example.invalid', now() - interval '20 days', now()),
    ('30000000-0000-4000-8000-000000000414', 'too-recent@example.invalid', now() - interval '5 days', now()),
    ('30000000-0000-4000-8000-000000000415', 'reactivated@example.invalid', now() - interval '20 days', now()),
    ('30000000-0000-4000-8000-000000000416', 'attributed@example.invalid', now() - interval '1 hour', now());


create or replace function pg_temp.meeting(
    p_id uuid, p_user uuid, p_start timestamptz, p_minutes int, p_origin text default null
) returns void language sql as $m$
    insert into public.meetings (id, user_id, title, summary, language, started_at, ended_at, created_at, origin)
    values (p_id, p_user, 'm', 's', 'en', p_start, p_start + make_interval(mins => p_minutes), p_start, p_origin);
$m$;

-- Everyone gets the sample on day 0, with its ticked action item.
select pg_temp.meeting(('40000000-0000-4000-8000-00000000' || lpad(n::text, 4, '0'))::uuid,
                       u, now() - interval '20 days' + interval '1 minute', 10, 'welcome')
from (values (1, '30000000-0000-4000-8000-000000000411'::uuid),
             (2, '30000000-0000-4000-8000-000000000412'::uuid),
             (3, '30000000-0000-4000-8000-000000000413'::uuid),
             (5, '30000000-0000-4000-8000-000000000415'::uuid)) v(n, u);
insert into public.action_items (user_id, meeting_id, text, done, done_at, source)
select m.user_id, m.id, 'sample task', true, m.started_at, 'recap'
from public.meetings m where m.origin = 'welcome' and m.user_id::text like '30000000-0000-4000-8000-0000000004%';

-- The real user: two recordings on different days, a summary view, a memory
-- question, a ticked task on a real meeting.
select pg_temp.meeting('40000000-0000-4000-8000-000000000102', '30000000-0000-4000-8000-000000000412', now() - interval '19 days', 30);
select pg_temp.meeting('40000000-0000-4000-8000-000000000103', '30000000-0000-4000-8000-000000000412', now() - interval '16 days', 20);
insert into public.product_events (id, user_id, occurred_at, app_session_id, event, platform, app_version, properties)
values
    (gen_random_uuid(), '30000000-0000-4000-8000-000000000412', now() - interval '19 days', gen_random_uuid(), 'app_opened', 'macos', '14.1.3', '{"entry_point":"app_launch"}'),
    (gen_random_uuid(), '30000000-0000-4000-8000-000000000412', now() - interval '19 days' + interval '1 hour', gen_random_uuid(), 'summary_viewed', 'macos', '14.1.3', '{}'),
    (gen_random_uuid(), '30000000-0000-4000-8000-000000000411', now() - interval '19 days', gen_random_uuid(), 'app_opened', 'macos', '14.1.3', '{"entry_point":"app_launch"}'),
    (gen_random_uuid(), '30000000-0000-4000-8000-000000000411', now() - interval '19 days' + interval '1 hour', gen_random_uuid(), 'summary_viewed', 'macos', '14.1.3', '{}');
insert into public.knowledge_threads (id, user_id)
values ('44000000-0000-4000-8000-000000000412', '30000000-0000-4000-8000-000000000412');
insert into public.knowledge_messages (thread_id, user_id, role, content, created_at)
values ('44000000-0000-4000-8000-000000000412', '30000000-0000-4000-8000-000000000412', 'user', 'what did we decide?', now() - interval '18 days');
insert into public.action_items (user_id, meeting_id, text, done, done_at, source)
values ('30000000-0000-4000-8000-000000000412', '40000000-0000-4000-8000-000000000102', 'real task', true, now() - interval '18 days', 'recap');

-- A question asked of the sample is not "tried chat".
insert into public.chat_messages (meeting_id, user_id, role, content)
values ('40000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000411', 'user', 'what is this?');

-- A streaming placeholder that never got audio.
select pg_temp.meeting('40000000-0000-4000-8000-000000000203', '30000000-0000-4000-8000-000000000413', now() - interval '19 days', 0);

-- Recorded, but signed up too recently for the 14-day window to have closed.
select pg_temp.meeting('40000000-0000-4000-8000-000000000304', '30000000-0000-4000-8000-000000000414', now() - interval '4 days', 15);

-- Recorded once, and later handed another fourteen days of trial.
select pg_temp.meeting('40000000-0000-4000-8000-000000000405', '30000000-0000-4000-8000-000000000415', now() - interval '18 days', 15);
insert into public.trial_reactivations (user_id, reactivated_at)
values ('30000000-0000-4000-8000-000000000415', now() - interval '2 days');

-- Google conversion: the sample must not fire it, a recording must.
insert into public.acquisition_touches (id, visitor_id, session_id, event, page_path, page_group, ga_client_id, consent_version)
values ('41000000-0000-4000-8000-000000000416', '42000000-0000-4000-8000-000000000416', '43000000-0000-4000-8000-000000000416',
        'page_view', '/', 'home', '123456789.123456789', 'web-v1');
insert into public.user_acquisition (user_id, first_touch_id, last_touch_id, coverage_status)
values ('30000000-0000-4000-8000-000000000416', '41000000-0000-4000-8000-000000000416', '41000000-0000-4000-8000-000000000416', 'attributed');
select pg_temp.meeting('40000000-0000-4000-8000-000000000506', '30000000-0000-4000-8000-000000000416', now() - interval '50 minutes', 10, 'welcome');

do $$
begin
    if exists (select 1 from public.google_conversion_outbox
                where user_id = '30000000-0000-4000-8000-000000000416' and event = 'activated') then
        raise exception 'the welcome sample must not fire the Google activation conversion';
    end if;
end $$;

select pg_temp.meeting('40000000-0000-4000-8000-000000000507', '30000000-0000-4000-8000-000000000416', now() - interval '30 minutes', 10);

do $$
begin
    if (select count(*) from public.google_conversion_outbox
         where user_id = '30000000-0000-4000-8000-000000000416' and event = 'activated') <> 1 then
        raise exception 'a real recording must fire the Google activation conversion once';
    end if;
end $$;

update public.meetings set ended_at = ended_at + interval '1 minute'
 where id = '40000000-0000-4000-8000-000000000506';
delete from public.google_conversion_outbox where user_id = '30000000-0000-4000-8000-000000000416';
select pg_temp.meeting('40000000-0000-4000-8000-000000000508', '30000000-0000-4000-8000-000000000416', now() - interval '20 minutes', 0);
update public.meetings set ended_at = started_at + interval '5 minutes'
 where id = '40000000-0000-4000-8000-000000000508';

do $$
begin
    if (select count(*) from public.google_conversion_outbox
         where user_id = '30000000-0000-4000-8000-000000000416' and event = 'activated') <> 1 then
        raise exception 'editing the sample must not fire; a placeholder that completes must fire once';
    end if;
end $$;

set local role authenticated;
set local request.jwt.claims = '{"sub":"30000000-0000-4000-8000-000000000401","email":"vlad@hellonod.app","role":"authenticated"}';
create temp table after_stages as select public.founder_activation_stages(14) as r;
create temp table after_activation as select public.founder_activation(1, 7) as r;
create temp table after_funnel as select * from public.founder_activation_funnel();
create temp table after_overview as select public.founder_overview(1, 7) as r;
create temp table after_retention as select * from public.founder_retention_cohorts(8);
create temp table after_metrics as select public.founder_metrics() as r;
create temp table after_onboarding as select public.founder_onboarding_activation(400, null) as r;
create temp table after_enriched as select * from public.founder_users_enriched(1, 7);
reset role;

create or replace function pg_temp.stage_delta(p_key text) returns bigint language sql as $d$
    select ((select r->'stages'->>p_key from after_stages)::bigint - (select r->'stages'->>p_key from before_stages)::bigint);
$d$;

do $$
declare
    b jsonb := (select r from before_stages);
    a jsonb := (select r from after_stages);
begin
    -- sample-only, real, zero-duration and reactivated signed up 20 days ago;
    -- too-recent and attributed did not close the window.
    if (a->>'cohort_size')::bigint - (b->>'cohort_size')::bigint <> 4 then
        raise exception 'cohort must hold the four accounts whose window closed: % → %', b->>'cohort_size', a->>'cohort_size';
    end if;
    if pg_temp.stage_delta('app_opened') <> 2 then
        raise exception 'app_opened counts the event, not a recording: %', pg_temp.stage_delta('app_opened');
    end if;
    if pg_temp.stage_delta('first_recording') <> 2 then
        raise exception 'first_recording must be real and positive: sample-only and zero-duration do not count: %', pg_temp.stage_delta('first_recording');
    end if;
    if pg_temp.stage_delta('repeat_recording_other_day') <> 1 then
        raise exception 'repeat_recording_other_day needs two real days: %', pg_temp.stage_delta('repeat_recording_other_day');
    end if;
    if pg_temp.stage_delta('summary_viewed') <> 1 then
        raise exception 'summary_viewed on the sample alone must not count: %', pg_temp.stage_delta('summary_viewed');
    end if;
    if pg_temp.stage_delta('asked_memory') <> 1 then
        raise exception 'asked_memory: %', pg_temp.stage_delta('asked_memory');
    end if;
    if pg_temp.stage_delta('completed_action_item') <> 1 then
        raise exception 'the sample''s pre-ticked task must not count as a completed action item: %', pg_temp.stage_delta('completed_action_item');
    end if;
    if (a->>'trial_reactivated_users')::bigint - (b->>'trial_reactivated_users')::bigint <> 1 then
        raise exception 'trial_reactivated_users must come from trial_reactivations, not status';
    end if;
end $$;

do $$
declare
    b jsonb := (select r from before_activation);
    a jsonb := (select r from after_activation);
    bo jsonb := (select r from before_overview);
    ao jsonb := (select r from after_overview);
begin
    -- "1 meeting in 7 days": real, zero-duration and reactivated are eligible
    -- (20 days old); only real and reactivated recorded for real.
    if (a->>'activated_users')::bigint - (b->>'activated_users')::bigint <> 2 then
        raise exception 'founder_activation must not activate the sample-only or zero-duration account: % → %', b->>'activated_users', a->>'activated_users';
    end if;
    if (ao->>'activated_users')::bigint - (bo->>'activated_users')::bigint <> 2 then
        raise exception 'founder_overview activated_users: % → %', bo->>'activated_users', ao->>'activated_users';
    end if;
    -- Neither the sample nor a zero-length placeholder is a recording.
    if (ao->>'never_recorded_count')::bigint - (bo->>'never_recorded_count')::bigint <> 2 then
        raise exception 'never_recorded_count must treat the sample as nothing recorded: % → %', bo->>'never_recorded_count', ao->>'never_recorded_count';
    end if;
end $$;

do $$
declare
    bm jsonb := (select r from before_metrics);
    am jsonb := (select r from after_metrics);
    bo jsonb := (select r from before_onboarding);
    ao jsonb := (select r from after_onboarding);
begin
    -- real ×2, too-recent, reactivated, attributed ×2 (one completed later) = 6 recordings
    if (am->>'total_meetings')::bigint - (bm->>'total_meetings')::bigint <> 6 then
        raise exception 'founder_metrics.total_meetings must count recordings only: %', (am->>'total_meetings')::bigint - (bm->>'total_meetings')::bigint;
    end if;
    if (am->>'chat_messages')::bigint - (bm->>'chat_messages')::bigint <> 0 then
        raise exception 'a question to the sample is not a chat message that counts';
    end if;
    -- 400-day signup window holds all six seeded accounts
    if (ao->'activation'->>'first_meeting')::bigint - (bo->'activation'->>'first_meeting')::bigint <> 4 then
        raise exception 'onboarding first_meeting must exclude sample-only and zero-duration: %', (ao->'activation'->>'first_meeting')::bigint - (bo->'activation'->>'first_meeting')::bigint;
    end if;
    if (ao->'activation'->>'second_meeting_within_three_days')::bigint - (bo->'activation'->>'second_meeting_within_three_days')::bigint <> 2 then
        raise exception 'onboarding second meeting: %', (ao->'activation'->>'second_meeting_within_three_days')::bigint - (bo->'activation'->>'second_meeting_within_three_days')::bigint;
    end if;
end $$;

do $$
declare
    d_first bigint := (select a.users - b.users from after_funnel a join before_funnel b on b.step = a.step where a.step = 'Ran 1st meeting');
    d_two bigint := (select a.users - b.users from after_funnel a join before_funnel b on b.step = a.step where a.step = 'Ran 2+ meetings');
    d_chat bigint := (select a.users - b.users from after_funnel a join before_funnel b on b.step = a.step where a.step = 'Tried AI chat');
begin
    -- real, reactivated, attributed recorded; too-recent too (no window here) → 4
    if d_first <> 4 then raise exception 'funnel "Ran 1st meeting" must exclude the sample and the zero-duration row: %', d_first; end if;
    if d_two <> 2 then raise exception 'funnel "Ran 2+ meetings": %', d_two; end if;
    if d_chat <> 1 then raise exception 'funnel "Tried AI chat" must include memory questions: %', d_chat; end if;
end $$;

do $$
declare
    wk date := date_trunc('week', now() - interval '20 days')::date;
    a record;
    b record;
begin
    select * into a from after_retention r where r.cohort_week = wk;
    select * into b from before_retention r where r.cohort_week = wk;
    if a is null then raise exception 'cohort week % missing', wk; end if;
    if not a.d1_mature or not a.d7_mature then
        raise exception 'a 20-day-old cohort has lived through day 1 and day 7';
    end if;
    if a.d30_mature or a.d30 is not null or a.d30_n is not null then
        raise exception 'd30 must be null until every member of the cohort has lived 30 days';
    end if;
    -- real user: recordings on day 1 and day 4 (signup−20d, meetings −19d and −16d)
    -- reactivated: day 2 (−18d). sample-only's day-0 sample counts nowhere.
    if a.d1_n - coalesce(b.d1_n, 0) <> 1 then
        raise exception 'd1 retained must be the real user alone: %', a.d1_n - coalesce(b.d1_n, 0);
    end if;
    if a.d7_n - coalesce(b.d7_n, 0) <> 2 then
        raise exception 'd7 retained must be real + reactivated: %', a.d7_n - coalesce(b.d7_n, 0);
    end if;
end $$;

do $$
declare
    sample record;
    realu record;
begin
    select * into sample from after_enriched e where e.user_id = '30000000-0000-4000-8000-000000000411';
    select * into realu from after_enriched e where e.user_id = '30000000-0000-4000-8000-000000000412';
    if sample.meetings_count <> 0 or sample.action_items_count <> 0 or sample.activated or sample.segment <> 'blocked' then
        raise exception 'sample-only account must read as blocked with nothing recorded: % % % %',
            sample.meetings_count, sample.action_items_count, sample.activated, sample.segment;
    end if;
    if (select e.segment from after_enriched e where e.user_id = '30000000-0000-4000-8000-000000000413') <> 'blocked' then
        raise exception 'a zero-length placeholder leaves the account blocked, not dormant';
    end if;
    if realu.chat_count <> 1 then
        raise exception 'chat_count must include the memory question: %', realu.chat_count;
    end if;
    if realu.meetings_count <> 2 or realu.action_items_count <> 1 or not realu.activated then
        raise exception 'real account must count only its recordings: % % %', realu.meetings_count, realu.action_items_count, realu.activated;
    end if;
end $$;

-- Nobody but a founder reads any of it.
set local role authenticated;
set local request.jwt.claims = '{"sub":"30000000-0000-4000-8000-000000000412","email":"real-user@example.invalid","role":"authenticated"}';
do $$
begin
    perform public.founder_activation_stages(14);
    raise exception 'a non-founder must not read activation stages';
exception when insufficient_privilege then null;
end $$;
reset role;

rollback;
