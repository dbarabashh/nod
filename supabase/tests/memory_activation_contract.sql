begin;
do $$
declare
    stage text;
    detail text;
begin
    foreach stage in array array['welcome', 'profile', 'permissions', 'tutorial', 'consent', 'authentication',
        'entitlement', 'vad', 'audio', 'capture', 'transcription', 'persistence', 'finalization',
        'notch', 'notch.intro', 'notch.microphone', 'notch.calendar', 'notch.plans', 'notch.permissions']
    loop
        if not public._valid_product_event_properties(jsonb_build_object('stage', stage, 'outcome', 'viewed')) then
            raise exception 'rejected supported stage %', stage;
        end if;
    end loop;
    foreach detail in array array['memory_off', 'memory_permission', 'memory_paused', 'memory_checking',
        'memory_waiting', 'memory_ready', 'memory_failed', 'open', 'pinned', 'project', 'follow_up']
    loop
        if not public._valid_product_event_properties(jsonb_build_object('surface', 'home', 'detail', detail)) then
            raise exception 'rejected supported detail %', detail;
        end if;
    end loop;
    if not array['question_asked','capture_started','memory_activation_viewed','memory_activation_acted']::text[]
        <@ public._client_product_events() then
        raise exception 'missing old or new event';
    end if;
    if public._valid_product_event_properties('{"stage":"notch.private-document"}'::jsonb)
        or public._valid_product_event_properties('{"detail":"memory_private-title"}'::jsonb)
        or public._valid_product_event_properties('{"question":"private question"}'::jsonb)
        or public._valid_product_event_properties('{"source_app":"private-app"}'::jsonb) then
        raise exception 'accepted unbounded or private content';
    end if;
end;
$$;

insert into auth.users (id, email, created_at, updated_at)
values ('91ab708e-7a41-4be6-9e09-f4600e58e578', 'memory-contract@example.invalid', now(), now());

set local role authenticated;
set local request.jwt.claims = '{"sub":"91ab708e-7a41-4be6-9e09-f4600e58e578"}';

do $$
declare
    result jsonb;
    event_name text;
    event_id uuid;
    payload jsonb;
begin
    foreach event_name in array array['capture_started', 'question_asked', 'memory_activation_viewed', 'memory_activation_acted']
    loop
        event_id := gen_random_uuid();
        payload := jsonb_build_array(jsonb_build_object(
            'id', event_id, 'occurred_at', now(), 'app_session_id', gen_random_uuid(),
            'event', event_name, 'platform', 'macos', 'app_version', '14.1.2+78',
            'properties', case when event_name like 'memory_%'
                then '{"surface":"home","detail":"memory_ready","outcome":"viewed"}'::jsonb
                else '{"entry_point":"hotkey","surface":"ask","detail":"follow_up"}'::jsonb end
        ));
        result := public.record_product_events(payload);
        if result ->> 'accepted' <> '1' or result ->> 'rejected' <> '0' then
            raise exception 'RPC rejected supported event %: %', event_name, result;
        end if;
        result := public.record_product_events(payload);
        if result ->> 'duplicates' <> '1' then
            raise exception 'RPC did not deduplicate %: %', event_name, result;
        end if;
    end loop;
    result := public.record_product_events(jsonb_build_array(jsonb_build_object(
        'id', gen_random_uuid(), 'occurred_at', now(), 'app_session_id', gen_random_uuid(),
        'event', 'memory_activation_acted', 'platform', 'macos', 'app_version', '14.1.2+78',
        'properties', '{"question":"private content"}'::jsonb
    )));
    if result ->> 'rejected' <> '1' then
        raise exception 'RPC accepted private content: %', result;
    end if;
    result := public.record_onboarding_events(gen_random_uuid(), jsonb_build_array(jsonb_build_object(
        'id', gen_random_uuid(), 'occurred_at', now(), 'app_session_id', gen_random_uuid(),
        'event', 'step_shown', 'platform', 'macos', 'app_version', '14.1.2+78',
        'properties', '{"stage":"notch.intro","outcome":"viewed"}'::jsonb
    )));
    if result ->> 'accepted' <> '1' then
        raise exception 'RPC rejected notch stage: %', result;
    end if;
end;
$$;
reset role;
do $$
begin
    if (select count(*) from public.product_events
        where user_id = '91ab708e-7a41-4be6-9e09-f4600e58e578') <> 4 then
        raise exception 'accepted events did not reach the table';
    end if;
end;
$$;
rollback;
