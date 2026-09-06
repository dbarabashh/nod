-- What it takes to reach somebody else's live meeting, and what it takes to
-- keep reaching it.
--
-- Five rules that were each true only in a comment before this. They are here
-- together because they are one story: knowing a conference link is not
-- permission, naming an organization is not membership, leaving is not staying,
-- and administering a team is not being in one.

begin;

insert into auth.users (id, email, created_at, updated_at)
values
    ('70000000-0000-4000-8000-000000000001', 'room-host@example.invalid', now(), now()),
    ('70000000-0000-4000-8000-000000000002', 'room-guest@example.invalid', now(), now()),
    ('70000000-0000-4000-8000-000000000003', 'room-outsider@example.invalid', now(), now());

insert into public.organizations (id, name, slug, created_by)
values ('71000000-0000-4000-8000-000000000001', 'Room Co', 'room-co',
        '70000000-0000-4000-8000-000000000001');

-- The outsider has an account and once knew this organization's id. They are
-- deliberately not a member of it.
insert into public.org_members (org_id, user_id, role, status)
values
    ('71000000-0000-4000-8000-000000000001', '70000000-0000-4000-8000-000000000001', 'owner', 'active'),
    ('71000000-0000-4000-8000-000000000001', '70000000-0000-4000-8000-000000000002', 'member', 'active');

-- The room answers only builds that speak the approval protocol. Off by default
-- in every environment, so the fixture turns it on the way a deploy does.
update public.app_config set live_room_required_build = 100 where platform = 'macos';
update public.profiles set app_build = 100
 where user_id in ('70000000-0000-4000-8000-000000000001',
                   '70000000-0000-4000-8000-000000000002',
                   '70000000-0000-4000-8000-000000000003');

-- ── A context has to be one you are in ──────────────────────────────────────

set local role authenticated;
set local request.jwt.claims = '{"sub":"70000000-0000-4000-8000-000000000003"}';

do $$
begin
    begin
        update public.profiles
           set active_org_id = '71000000-0000-4000-8000-000000000001'
         where user_id = '70000000-0000-4000-8000-000000000003';
        raise exception 'a stranger set their working context to somebody elses organization';
    exception
        when insufficient_privilege then null;
    end;
end;
$$;

-- A member setting their own organization is the ordinary case and still works.
set local request.jwt.claims = '{"sub":"70000000-0000-4000-8000-000000000002"}';

do $$
begin
    update public.profiles
       set active_org_id = '71000000-0000-4000-8000-000000000001'
     where user_id = '70000000-0000-4000-8000-000000000002';
end;
$$;

-- ── Knowing the room is not being in it ─────────────────────────────────────

reset role;

insert into public.meetings (id, user_id, started_at, ended_at, summary, title)
values ('72000000-0000-4000-8000-000000000001', '70000000-0000-4000-8000-000000000001',
        now(), now(), 'what was said', 'Weekly sync');

insert into public.meeting_start_leases
    (meeting_id, user_id, org_id, status, granted_at, expires_at, last_used_at)
values ('72000000-0000-4000-8000-000000000001', '70000000-0000-4000-8000-000000000001',
        '71000000-0000-4000-8000-000000000001', 'active', now(), now() + interval '1 hour', now());

-- Set after the fact: `_stamp_lease_identity` is a BEFORE INSERT trigger that
-- derives both keys from the host's synced calendar, and there is no calendar
-- here — so anything supplied to the insert is overwritten with null.
update public.meeting_start_leases
   set ical_uid = 'weekly-sync-uid', room_key = 'zoom:5551234567'
 where meeting_id = '72000000-0000-4000-8000-000000000001';

-- The guest is in the organization and names the room correctly — and has no
-- calendar entry saying they are in this meeting. That is a request, not entry.
set local role authenticated;
set local request.jwt.claims = '{"sub":"70000000-0000-4000-8000-000000000002"}';

do $$
declare
    v_status text;
begin
    select status into v_status
      from public.join_live_room(null, 'https://zoom.us/j/5551234567');
    if v_status is distinct from 'pending' then
        raise exception 'joining a room with no proof of attendance gave %, not a request', coalesce(v_status, 'nothing');
    end if;
end;
$$;

-- ── A build that cannot answer is not offered the room ──────────────────────
--
-- Both ends. A listener too old to understand `pending` would watch a bar that
-- never fills; a host too old would never see the request. Neither is told
-- anything, so the room simply is not there.

reset role;
update public.profiles set app_build = 99 where user_id = '70000000-0000-4000-8000-000000000002';
set local role authenticated;
set local request.jwt.claims = '{"sub":"70000000-0000-4000-8000-000000000002"}';

do $$
begin
    if exists (select 1 from public.find_live_room(null, 'https://zoom.us/j/5551234567')) then
        raise exception 'a build below the gate was offered a live room';
    end if;
    if exists (select 1 from public.join_live_room(null, 'https://zoom.us/j/5551234567')) then
        raise exception 'a build below the gate joined a live room';
    end if;
end;
$$;

reset role;
update public.profiles set app_build = 100 where user_id = '70000000-0000-4000-8000-000000000002';
update public.profiles set app_build = 99 where user_id = '70000000-0000-4000-8000-000000000001';
set local role authenticated;
set local request.jwt.claims = '{"sub":"70000000-0000-4000-8000-000000000002"}';

do $$
begin
    if exists (select 1 from public.find_live_room(null, 'https://zoom.us/j/5551234567')) then
        raise exception 'a room hosted by a build that cannot answer was still offered';
    end if;
end;
$$;

reset role;
update public.profiles set app_build = 100 where user_id = '70000000-0000-4000-8000-000000000001';
set local role authenticated;
set local request.jwt.claims = '{"sub":"70000000-0000-4000-8000-000000000002"}';

-- Discovery says a recording exists and refuses to say whose. The host is never
-- told this was asked, so a name here would be a presence feed on a colleague.
do $$
declare
    v_name text;
    v_rows int;
begin
    select count(*), max(host_name) into v_rows, v_name
      from public.find_live_room(null, 'https://zoom.us/j/5551234567');
    if v_rows <> 1 then
        raise exception 'discovery did not find a live recording it should have';
    end if;
    if v_name is not null then
        raise exception 'discovery named the host to somebody with no claim to the meeting';
    end if;
end;
$$;

-- A pending request reads nothing at all.
do $$
begin
    if public.is_live_room_listener('72000000-0000-4000-8000-000000000001') then
        raise exception 'an unanswered request could already read the transcript';
    end if;
    if exists (select 1 from public.meetings where id = '72000000-0000-4000-8000-000000000001') then
        raise exception 'an unanswered request could already read the meeting';
    end if;
end;
$$;

-- ── Two keys are not one meeting ────────────────────────────────────────────
--
-- The guest now has a calendar entry of their own, happening now, for a
-- different meeting. Supplying the victim's room *and* their own invitation
-- satisfies "find the host" and "prove attendance" with two unrelated keys, and
-- must still be a request: the proof is asked against the host's lease, not
-- against whatever the caller sent.

reset role;

insert into public.calendar_events (user_id, calendar_id, external_event_id, ical_uid, title, starts_at, ends_at)
values ('70000000-0000-4000-8000-000000000002', 'primary', 'my-standup', 'my-own-standup',
        'My standup', now(), now() + interval '30 minutes');

update public.room_listeners set left_at = now()
 where host_meeting_id = '72000000-0000-4000-8000-000000000001';

set local role authenticated;
set local request.jwt.claims = '{"sub":"70000000-0000-4000-8000-000000000002"}';

do $$
declare
    v_status text;
begin
    select status into v_status
      from public.join_live_room('my-own-standup', 'https://zoom.us/j/5551234567');
    if v_status is distinct from 'pending' then
        raise exception 'an unrelated calendar entry proved attendance at somebody elses meeting (got %)', coalesce(v_status, 'nothing');
    end if;
end;
$$;

-- ── The calendar the server read does open the room ─────────────────────────
--
-- The other direction, which is the one a regression hides in: when the guest's
-- own synced calendar carries the meeting the host is recording, there is
-- nothing for the host to answer.

reset role;

update public.room_listeners set left_at = now()
 where host_meeting_id = '72000000-0000-4000-8000-000000000001';

insert into public.calendar_events (user_id, calendar_id, external_event_id, ical_uid, title, starts_at, ends_at)
values ('70000000-0000-4000-8000-000000000002', 'primary', 'the-sync', 'weekly-sync-uid',
        'Weekly sync', now(), now() + interval '30 minutes');

set local role authenticated;
set local request.jwt.claims = '{"sub":"70000000-0000-4000-8000-000000000002"}';

do $$
declare
    v_status text;
begin
    select status into v_status
      from public.join_live_room('weekly-sync-uid', null);
    if v_status is distinct from 'joined' then
        raise exception 'a guest whose own calendar carries this meeting was not let in (got %)', coalesce(v_status, 'nothing');
    end if;
end;
$$;

-- ── Only the host approves, and approving works ─────────────────────────────

reset role;

update public.room_listeners set left_at = now(), status = 'denied'
 where host_meeting_id = '72000000-0000-4000-8000-000000000001';

delete from public.calendar_events where user_id = '70000000-0000-4000-8000-000000000002';

set local role authenticated;
set local request.jwt.claims = '{"sub":"70000000-0000-4000-8000-000000000002"}';

do $$
declare
    v_status text;
begin
    select status into v_status
      from public.join_live_room(null, 'https://zoom.us/j/5551234567');
    if v_status is distinct from 'pending' then
        raise exception 'a guest with no calendar proof was not made to ask (got %)', coalesce(v_status, 'nothing');
    end if;
end;
$$;

-- ── Only the host answers ───────────────────────────────────────────────────

do $$
declare
    v_listener uuid;
begin
    select id into v_listener from public.room_listeners
     where host_meeting_id = '72000000-0000-4000-8000-000000000001' and left_at is null;

    begin
        perform public.approve_room_listener(v_listener);
        raise exception 'a listener approved their own request to listen';
    exception
        when insufficient_privilege then null;
    end;
end;
$$;

-- ── Leaving ends the read of the meeting, not only of the transcript ────────

reset role;

update public.room_listeners set status = 'joined'
 where host_meeting_id = '72000000-0000-4000-8000-000000000001';

set local role authenticated;
set local request.jwt.claims = '{"sub":"70000000-0000-4000-8000-000000000002"}';

do $$
begin
    if not exists (select 1 from public.meetings where id = '72000000-0000-4000-8000-000000000001') then
        raise exception 'an approved listener could not read the meeting they are listening to';
    end if;
end;
$$;

do $$
declare
    v_listener uuid;
begin
    select id into v_listener from public.room_listeners
     where host_meeting_id = '72000000-0000-4000-8000-000000000001' and left_at is null;
    perform public.leave_live_room(v_listener);

    if exists (select 1 from public.meetings where id = '72000000-0000-4000-8000-000000000001') then
        raise exception 'somebody who left the room kept reading the meeting';
    end if;
end;
$$;

-- ── A meeting's identity is not the client's to rewrite ─────────────────────

reset role;

insert into public.meetings (id, user_id, started_at, ended_at, summary, title)
values ('72000000-0000-4000-8000-000000000002', '70000000-0000-4000-8000-000000000002',
        now(), now(), 'mine', 'My own session');

set local role authenticated;
set local request.jwt.claims = '{"sub":"70000000-0000-4000-8000-000000000002"}';

do $$
declare
    v_room text;
begin
    update public.meetings
       set room_key = 'zoom:5551234567', ical_uid = 'weekly-sync-uid'
     where id = '72000000-0000-4000-8000-000000000002';

    select room_key into v_room from public.meetings
     where id = '72000000-0000-4000-8000-000000000002';
    if v_room is not null then
        raise exception 'a client claimed somebody elses conference room on its own meeting';
    end if;
end;
$$;

-- ── Administering a team is not being in one ────────────────────────────────

reset role;

insert into public.teams (id, org_id, name, created_by)
values ('73000000-0000-4000-8000-000000000001', '71000000-0000-4000-8000-000000000001', 'Product',
        '70000000-0000-4000-8000-000000000001');

set local role authenticated;
set local request.jwt.claims = '{"sub":"70000000-0000-4000-8000-000000000001"}';

do $$
begin
    begin
        perform public.add_team_member('73000000-0000-4000-8000-000000000001',
                                       '70000000-0000-4000-8000-000000000001');
        raise exception 'an administrator added themselves to a team';
    exception
        when insufficient_privilege then null;
    end;

    -- Adding somebody else is the whole point of the function and still works.
    perform public.add_team_member('73000000-0000-4000-8000-000000000001',
                                   '70000000-0000-4000-8000-000000000002');
end;
$$;

reset role;

-- A membership somebody else wrote is an ordinary one and carries the content.
-- Asked as postgres: the helper answers only its definer callers now, and a
-- signed-in role may not call it directly.
do $$
begin
    if not public._team_membership_grants_content('73000000-0000-4000-8000-000000000001',
                                                  '70000000-0000-4000-8000-000000000002') then
        raise exception 'a member added by an administrator lost the teams content';
    end if;
end;
$$;

set local role authenticated;
do $$
begin
    begin
        perform public._team_membership_grants_content('73000000-0000-4000-8000-000000000001',
                                                       '70000000-0000-4000-8000-000000000002');
        raise exception 'a signed-in role called the membership helper directly';
    exception
        when insufficient_privilege then null;
    end;
end;
$$;
reset role;

-- ── Two administrators writing each other in is the self-add, once removed ──

update public.org_members set role = 'admin'
 where org_id = '71000000-0000-4000-8000-000000000001'
   and user_id = '70000000-0000-4000-8000-000000000002';

-- The pair: each names the other as the one who added them.
delete from public.team_members where team_id = '73000000-0000-4000-8000-000000000001';
insert into public.team_members (team_id, user_id, added_by) values
    ('73000000-0000-4000-8000-000000000001', '70000000-0000-4000-8000-000000000001',
     '70000000-0000-4000-8000-000000000002'),
    ('73000000-0000-4000-8000-000000000001', '70000000-0000-4000-8000-000000000002',
     '70000000-0000-4000-8000-000000000001');

do $$
begin
    if public._team_membership_grants_content('73000000-0000-4000-8000-000000000001',
                                              '70000000-0000-4000-8000-000000000001')
       or public._team_membership_grants_content('73000000-0000-4000-8000-000000000001',
                                                 '70000000-0000-4000-8000-000000000002') then
        raise exception 'two administrators wrote each other into a team and kept its content';
    end if;
end;
$$;

-- ── A device claim only matches what it was recorded beside ─────────────────

reset role;

insert into public.meetings (id, user_id, started_at, ended_at, summary, title)
values ('74000000-0000-4000-8000-000000000001', '70000000-0000-4000-8000-000000000001',
        now() - interval '3 hours', now() - interval '2 hours', 'x', 'Board comp review'),
       ('74000000-0000-4000-8000-000000000002', '70000000-0000-4000-8000-000000000002',
        now(), now(), 'y', 'Mine');

insert into public.meeting_start_leases
    (meeting_id, user_id, org_id, status, granted_at, expires_at, last_used_at)
values ('74000000-0000-4000-8000-000000000002', '70000000-0000-4000-8000-000000000002',
        '71000000-0000-4000-8000-000000000001', 'active', now(), now() + interval '1 hour', now());

-- Both name the same room. The victim's was read from their calendar; the
-- caller's was claimed by their device, and the two recordings do not overlap.
update public.meetings set room_key = 'zoom:9998887777'
 where id in ('74000000-0000-4000-8000-000000000001', '74000000-0000-4000-8000-000000000002');
update public.meeting_start_leases
   set room_key = 'zoom:9998887777', identity_source = 'device'
 where meeting_id = '74000000-0000-4000-8000-000000000002';

set local role authenticated;
set local request.jwt.claims = '{"sub":"70000000-0000-4000-8000-000000000002"}';

do $$
declare
    v_found int;
begin
    select count(*) into v_found
      from public.same_meeting_in_org('74000000-0000-4000-8000-000000000002');
    if v_found <> 0 then
        raise exception 'a claimed room key reached a meeting recorded at another time';
    end if;
end;
$$;

-- The same claim, against a recording it actually overlapped, is the merge
-- prompt the feature exists for.
reset role;

update public.meetings set started_at = now() - interval '4 minutes', ended_at = now()
 where id = '74000000-0000-4000-8000-000000000001';

set local role authenticated;
set local request.jwt.claims = '{"sub":"70000000-0000-4000-8000-000000000002"}';

do $$
declare
    v_found int;
begin
    select count(*) into v_found
      from public.same_meeting_in_org('74000000-0000-4000-8000-000000000002');
    if v_found <> 1 then
        raise exception 'two people recording one call were not offered the merge (got %)', v_found;
    end if;
end;
$$;

rollback;
