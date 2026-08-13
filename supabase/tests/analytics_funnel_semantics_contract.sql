begin;

insert into auth.users (id, email, created_at, updated_at)
values (
    '10000000-0000-4000-8000-000000000085',
    'analytics-funnel@example.invalid',
    now() - interval '1 hour',
    now()
);

insert into public.acquisition_touches (
    id, visitor_id, session_id, event, page_path, page_group, ga_client_id, consent_version
) values (
    '20000000-0000-4000-8000-000000000085',
    '30000000-0000-4000-8000-000000000085',
    '40000000-0000-4000-8000-000000000085',
    'page_view', '/', 'home', '123456789.123456789', 'web-v1'
);

insert into public.user_acquisition (user_id, first_touch_id, last_touch_id, coverage_status)
values (
    '10000000-0000-4000-8000-000000000085',
    '20000000-0000-4000-8000-000000000085',
    '20000000-0000-4000-8000-000000000085',
    'attributed'
);

insert into public.meetings (
    id, user_id, title, summary, language, started_at, ended_at, created_at
) values (
    '50000000-0000-4000-8000-000000000085',
    '10000000-0000-4000-8000-000000000085',
    'streaming placeholder', '', 'en', now(), now(), now()
);

do $$
begin
    if exists (
        select 1 from public.google_conversion_outbox
        where user_id = '10000000-0000-4000-8000-000000000085' and event = 'activated'
    ) then
        raise exception 'zero-duration placeholder unexpectedly activated the signup';
    end if;
end;
$$;

update public.meetings
set ended_at = started_at + interval '5 minutes'
where id = '50000000-0000-4000-8000-000000000085';

do $$
begin
    if (select count(*) from public.google_conversion_outbox
        where user_id = '10000000-0000-4000-8000-000000000085' and event = 'activated') <> 1 then
        raise exception 'completed meeting must enqueue activation exactly once';
    end if;
end;
$$;

update public.meetings
set ended_at = ended_at + interval '1 minute'
where id = '50000000-0000-4000-8000-000000000085';

do $$
begin
    if (select count(*) from public.google_conversion_outbox
        where user_id = '10000000-0000-4000-8000-000000000085' and event = 'activated') <> 1 then
        raise exception 'completed meeting update must remain idempotent';
    end if;
end;
$$;

rollback;
