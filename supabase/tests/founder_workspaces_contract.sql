begin;

insert into auth.users (id, email, created_at, updated_at)
values
    ('10000000-0000-4000-8000-000000000301', 'vlad@hellonod.app', now() - interval '200 days', now()),
    ('10000000-0000-4000-8000-000000000311', 'solo-founder@example.invalid', now() - interval '30 days', now()),
    ('10000000-0000-4000-8000-000000000312', 'team-lead@example.invalid', now() - interval '30 days', now()),
    ('10000000-0000-4000-8000-000000000313', 'joiner@example.invalid', now() - interval '30 days', now());

-- A room one person made and never invited anyone into. In a count(*) this is
-- indistinguishable from the one below; the whole point is that it must not be.
insert into public.organizations (id, name, slug, created_by, created_at)
values ('50000000-0000-4000-8000-000000000101', 'Empty room', 'empty-room-contract',
        '10000000-0000-4000-8000-000000000311', now() - interval '10 days');
insert into public.org_members (org_id, user_id, role, status, joined_at)
values ('50000000-0000-4000-8000-000000000101', '10000000-0000-4000-8000-000000000311',
        'owner', 'active', now() - interval '10 days');

-- A workspace a team actually moved into: one accepted invite, one still live,
-- one revoked, one expired, a team, and work stamped to it.
insert into public.organizations (id, name, slug, created_by, created_at)
values ('50000000-0000-4000-8000-000000000102', 'Moved in', 'moved-in-contract',
        '10000000-0000-4000-8000-000000000312', now() - interval '5 days');
insert into public.org_members (org_id, user_id, role, status, joined_at)
values
    ('50000000-0000-4000-8000-000000000102', '10000000-0000-4000-8000-000000000312', 'owner', 'active', now() - interval '5 days'),
    ('50000000-0000-4000-8000-000000000102', '10000000-0000-4000-8000-000000000313', 'member', 'active', now() - interval '4 days'),
    ('50000000-0000-4000-8000-000000000102', '10000000-0000-4000-8000-000000000301', 'member', 'deprovisioned', now() - interval '3 days');

insert into public.org_invites (org_id, email, role, invited_by, created_at, expires_at, accepted_at, accepted_by, revoked_at)
values
    ('50000000-0000-4000-8000-000000000102', 'joiner@example.invalid', 'member', '10000000-0000-4000-8000-000000000312', now() - interval '5 days', now() + interval '5 days', now() - interval '4 days', '10000000-0000-4000-8000-000000000313', null),
    ('50000000-0000-4000-8000-000000000102', 'still-thinking@example.invalid', 'member', '10000000-0000-4000-8000-000000000312', now() - interval '2 days', now() + interval '5 days', null, null, null),
    ('50000000-0000-4000-8000-000000000102', 'changed-mind@example.invalid', 'member', '10000000-0000-4000-8000-000000000312', now() - interval '3 days', now() + interval '5 days', null, null, now() - interval '1 day'),
    ('50000000-0000-4000-8000-000000000102', 'too-late@example.invalid', 'member', '10000000-0000-4000-8000-000000000312', now() - interval '9 days', now() - interval '1 day', null, null, null);

insert into public.teams (id, org_id, name, created_by, created_at)
values ('60000000-0000-4000-8000-000000000001', '50000000-0000-4000-8000-000000000102', 'Sales', '10000000-0000-4000-8000-000000000312', now() - interval '4 days');
-- A deleted team is not a team the workspace has.
insert into public.teams (id, org_id, name, created_by, created_at, deleted_at)
values ('60000000-0000-4000-8000-000000000002', '50000000-0000-4000-8000-000000000102', 'Gone', '10000000-0000-4000-8000-000000000312', now() - interval '4 days', now() - interval '2 days');

insert into public.meetings (user_id, org_id, created_at, started_at, ended_at, summary)
values ('10000000-0000-4000-8000-000000000313', '50000000-0000-4000-8000-000000000102',
        now() - interval '2 days', now() - interval '2 days', now() - interval '2 days' + interval '1 hour', 'seed');
insert into public.usage_events (user_id, org_id, created_at, kind, model, status, audio_seconds, cost_usd, task)
values ('10000000-0000-4000-8000-000000000313', '50000000-0000-4000-8000-000000000102',
        now() - interval '2 days', 'transcribe', 'openrouter:openai/gpt-4o-transcribe', 200, 3600, 0.40, 'stt');

-- Our own test workspace: flagged, never dropped.
insert into public.organizations (id, name, slug, created_by, created_at)
values ('50000000-0000-4000-8000-000000000103', 'Internal', 'internal-contract',
        '10000000-0000-4000-8000-000000000301', now() - interval '1 day');

set local role authenticated;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000301","email":"vlad@hellonod.app","role":"authenticated"}';

do $$
declare
    v_empty record;
    v_moved record;
begin
    select * into v_empty from public.founder_workspaces()
     where org_id = '50000000-0000-4000-8000-000000000101';
    select * into v_moved from public.founder_workspaces()
     where org_id = '50000000-0000-4000-8000-000000000102';

    -- A room nobody was invited into must read as exactly that.
    if v_empty.members_active <> 1 or v_empty.invites_sent <> 0
       or v_empty.meetings <> 0 or v_empty.teams <> 0 then
        raise exception 'an empty workspace did not read as empty';
    end if;

    -- Seat-holders and everyone else are counted apart, never summed.
    if v_moved.members_active <> 2 or v_moved.members_other <> 1 then
        raise exception 'membership states were merged';
    end if;

    -- Pending means "can still be accepted": revoked and expired are not.
    if v_moved.invites_sent <> 4 or v_moved.invites_accepted <> 1
       or v_moved.invites_pending <> 1 or v_moved.invites_dead <> 2 then
        raise exception 'invite states are wrong';
    end if;

    if v_moved.teams <> 1 then
        raise exception 'a deleted team was still counted';
    end if;

    if v_moved.meetings <> 1 or v_moved.transcription_hours <> 1.00
       or v_moved.cost_usd <> 0.40 or v_moved.last_activity_at is null then
        raise exception 'work stamped to the workspace did not reach the row';
    end if;

    -- Nobody is paying yet, and that must read as absent rather than as zero.
    if v_moved.plan is not null or v_moved.seats is not null then
        raise exception 'an unpurchased workspace reported a plan';
    end if;

    -- Our own workspace is flagged, and a customer's is not.
    if not (select creator_is_internal from public.founder_workspaces()
             where org_id = '50000000-0000-4000-8000-000000000103')
       or v_moved.creator_is_internal then
        raise exception 'internal flagging is wrong';
    end if;

    -- Newest first: the founder is looking for whether anyone made one lately.
    if (select org_id from public.founder_workspaces() limit 1)
       <> '50000000-0000-4000-8000-000000000103' then
        raise exception 'workspaces are not ordered newest first';
    end if;
end;
$$;
reset role;

set local role authenticated;
set local request.jwt.claims = '{"sub":"10000000-0000-4000-8000-000000000311","email":"solo-founder@example.invalid","role":"authenticated"}';
do $$
begin
    begin
        perform public.founder_workspaces();
        raise exception 'a non-founder read the workspace list';
    exception when insufficient_privilege then null;
    end;
end;
$$;
reset role;

set local role anon;
set local request.jwt.claims = '{}';
do $$
begin
    begin
        perform public.founder_workspaces();
        raise exception 'anon read the workspace list';
    exception when insufficient_privilege then null;
    end;
end;
$$;
reset role;

rollback;
