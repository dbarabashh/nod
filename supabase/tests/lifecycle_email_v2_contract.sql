begin;

do $$
begin
    if (select policy_version from public.email_program_config where singleton) <> 'communications-v2' then
        raise exception 'email policy version must be communications-v2';
    end if;
    if (select program_not_before from public.email_program_config where singleton) is not null then
        raise exception 'v2 policy must reset the program gate';
    end if;
    if exists (
        select 1 from public.email_campaigns
         where email_class <> 'transactional' and rollout_mode <> 'off'
    ) then
        raise exception 'optional campaigns must start off';
    end if;
    if not exists (
        select 1 from public.email_campaigns
         where campaign_key = 'trial-learning-day-1'
           and accepted_policy_versions = array['communications-v2']
    ) then
        raise exception 'trial learning must require communications-v2';
    end if;
    if not exists (
        select 1 from public.email_campaigns
         where campaign_key = 'activation-second-meeting'
           and accepted_policy_versions @> array['communications-v1', 'communications-v2']
    ) then
        raise exception 'standard activation must preserve v1 consent';
    end if;
end;
$$;

insert into auth.users (id, email, created_at, updated_at)
values (
    '10000000-0000-4000-8000-000000000089',
    'lifecycle-contract@example.invalid',
    now() - interval '5 days',
    now()
);

insert into public.meetings (id, user_id, title, summary, language, started_at, ended_at, created_at)
values
    (
        '50000000-0000-4000-8000-000000000089',
        '10000000-0000-4000-8000-000000000089',
        'placeholder', '', 'en', now() - interval '4 days', now() - interval '4 days', now()
    ),
    (
        '50000000-0000-4000-8000-000000000090',
        '10000000-0000-4000-8000-000000000089',
        'first', '', 'en', now() - interval '3 days', now() - interval '3 days' + interval '5 minutes', now()
    ),
    (
        '50000000-0000-4000-8000-000000000091',
        '10000000-0000-4000-8000-000000000089',
        'second', '', 'en', now() - interval '2 days', now() - interval '2 days' + interval '5 minutes', now()
    );

do $$
declare
    v_snapshot record;
begin
    select * into v_snapshot
      from public.email_user_snapshots()
     where user_id = '10000000-0000-4000-8000-000000000089';
    if v_snapshot.completed_meetings <> 2 then
        raise exception 'zero-duration meeting counted as completed';
    end if;
    if not v_snapshot.is_activated then
        raise exception 'second positive-duration meeting within three days must activate';
    end if;
end;
$$;

rollback;
