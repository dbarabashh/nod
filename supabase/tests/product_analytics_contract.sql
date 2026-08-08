begin;

insert into auth.users (id, email, created_at, updated_at)
values (
    '10000000-0000-4000-8000-000000000001',
    'analytics-contract@example.invalid',
    now(),
    now()
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000001"}';

do $$
declare
    v_result jsonb;
begin
    select public.record_product_events(jsonb_build_array(jsonb_build_object(
        'id', '20000000-0000-4000-8000-000000000001',
        'occurred_at', now(),
        'app_session_id', '30000000-0000-4000-8000-000000000001',
        'capture_id', '40000000-0000-4000-8000-000000000001',
        'event', 'capture_started',
        'platform', 'macos',
        'app_version', '12.11.5+62',
        'properties', jsonb_build_object(
            'session_kind', 'meeting',
            'entry_point', 'floating_panel',
            'stage', 'audio'
        )
    ))) into v_result;
    if v_result ->> 'accepted' <> '1' then
        raise exception 'expected one accepted product event: %', v_result;
    end if;

    select public.record_product_events(jsonb_build_array(jsonb_build_object(
        'id', '20000000-0000-4000-8000-000000000001',
        'occurred_at', now(),
        'app_session_id', '30000000-0000-4000-8000-000000000001',
        'capture_id', '40000000-0000-4000-8000-000000000001',
        'event', 'capture_started',
        'platform', 'macos',
        'app_version', '12.11.5+62',
        'properties', '{}'::jsonb
    ))) into v_result;
    if v_result ->> 'duplicates' <> '1' then
        raise exception 'expected duplicate product event: %', v_result;
    end if;

    select public.record_product_events(jsonb_build_array(jsonb_build_object(
        'id', '20000000-0000-4000-8000-000000000002',
        'occurred_at', now(),
        'app_session_id', '30000000-0000-4000-8000-000000000001',
        'event', 'summary_viewed',
        'platform', 'macos',
        'app_version', '12.11.5+62',
        'properties', jsonb_build_object('meeting_title', 'must not be accepted')
    ))) into v_result;
    if v_result ->> 'rejected' <> '1' then
        raise exception 'expected arbitrary property rejection: %', v_result;
    end if;

    select public.record_product_events(jsonb_build_array(jsonb_build_object(
        'id', '20000000-0000-4000-8000-000000000003',
        'occurred_at', 'not-a-timestamp',
        'app_session_id', '30000000-0000-4000-8000-000000000001',
        'event', 'app_opened',
        'platform', 'macos',
        'app_version', '12.11.5+62',
        'properties', '{}'::jsonb
    ))) into v_result;
    if v_result ->> 'rejected' <> '1' then
        raise exception 'expected malformed timestamp rejection: %', v_result;
    end if;
end;
$$;

do $$
begin
    insert into public.product_events (
        id, user_id, occurred_at, app_session_id, event, platform, app_version
    ) values (
        '20000000-0000-4000-8000-000000000099',
        auth.uid(),
        now(),
        '30000000-0000-4000-8000-000000000001',
        'app_opened',
        'macos',
        '12.11.5+62'
    );
    raise exception 'direct product_events insert unexpectedly succeeded';
exception
    when insufficient_privilege then null;
end;
$$;

reset role;
set local role anon;
set local request.jwt.claims = '{}';

do $$
declare
    v_result jsonb;
begin
    select public.record_onboarding_events(
        '50000000-0000-4000-8000-000000000001',
        jsonb_build_array(jsonb_build_object(
            'id', '60000000-0000-4000-8000-000000000001',
            'occurred_at', now(),
            'app_session_id', '70000000-0000-4000-8000-000000000001',
            'event', 'analytics_consent_resolved',
            'platform', 'ios',
            'app_version', '1.0.0+1',
            'properties', jsonb_build_object(
                'stage', 'consent',
                'outcome', 'granted'
            )
        ))
    ) into v_result;
    if v_result ->> 'accepted' <> '1' then
        raise exception 'expected anonymous onboarding acceptance: %', v_result;
    end if;

    select public.record_onboarding_events(
        '50000000-0000-4000-8000-000000000001',
        jsonb_agg(jsonb_build_object('id', gen_random_uuid()))
    )
    into v_result
    from generate_series(1, 26);
    if v_result ->> 'rejected' <> '1' then
        raise exception 'expected oversized onboarding batch rejection: %', v_result;
    end if;
end;
$$;

reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000001"}';

do $$
declare
    v_claimed integer;
begin
    select public.claim_onboarding_installation(
        '50000000-0000-4000-8000-000000000001'
    ) into v_claimed;
    if v_claimed <> 1 then
        raise exception 'expected one claimed onboarding event, got %', v_claimed;
    end if;
end;
$$;

reset role;

insert into public.meetings (
    id, user_id, title, summary, language, started_at, ended_at, created_at
) values (
    '80000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000001',
    'contract fixture',
    'contract summary',
    'en',
    now() - interval '5 minutes',
    now(),
    now()
);

insert into public.meeting_shares (token, meeting_id, created_by)
values (
    '90000000-0000-4000-8000-000000000001',
    '80000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000001'
);

set local role anon;
set local request.jwt.claims = '{}';

do $$
begin
    if not public.record_share_view(
        '90000000-0000-4000-8000-000000000001',
        'a0000000-0000-4000-8000-000000000001',
        'b0000000-0000-4000-8000-000000000001'
    ) then
        raise exception 'expected live share view to be accepted';
    end if;
    if not public.record_share_view(
        '90000000-0000-4000-8000-000000000001',
        'a0000000-0000-4000-8000-000000000002',
        'b0000000-0000-4000-8000-000000000001'
    ) then
        raise exception 'expected duplicate session view to be idempotent';
    end if;
end;
$$;

reset role;
do $$
begin
    if (select count(*) from public.share_product_events) <> 1 then
        raise exception 'share view must be unique per browser session';
    end if;
end;
$$;

update public.meeting_shares
set revoked_at = now()
where token = '90000000-0000-4000-8000-000000000001';

set local role anon;
do $$
begin
    if public.record_share_view(
        '90000000-0000-4000-8000-000000000001',
        'a0000000-0000-4000-8000-000000000003',
        'b0000000-0000-4000-8000-000000000002'
    ) then
        raise exception 'revoked share view unexpectedly succeeded';
    end if;
end;
$$;

reset role;
delete from auth.users where id = '10000000-0000-4000-8000-000000000001';

do $$
begin
    if exists (select 1 from public.product_events) then
        raise exception 'product events did not cascade on account deletion';
    end if;
    if exists (select 1 from public.onboarding_events where user_id is not null) then
        raise exception 'claimed onboarding events did not cascade on account deletion';
    end if;
end;
$$;

rollback;
