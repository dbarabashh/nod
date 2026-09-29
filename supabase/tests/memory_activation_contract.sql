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
rollback;
