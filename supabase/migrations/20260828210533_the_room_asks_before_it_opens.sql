-- Listening to somebody's meeting stops being something you can simply assert.
--
-- `20260815184500` stated the rule this feature was supposed to hold to: "the
-- only way to reach somebody's live transcript is to be able to prove, from your
-- own calendar, that you are in the same meeting. A colleague who is not in the
-- meeting has nothing to send that would match." Nothing implemented it. Both
-- `p_ical_uid` and `p_conference_url` are free text on an RPC granted to
-- `authenticated`, and the match was made against the *host's* lease alone. The
-- proof lived in the macOS client, which decides what to send — and a client is
-- not where an authorization check can live.
--
-- The identities are not secrets. `conference_room_key` deliberately normalizes
-- a personal room — `webex.com/meet/<name>`, a Zoom PMI, a standing Meet code —
-- to one stable string so it matches across occurrences, which also means one
-- invitation ever received, or a link in an email signature, names that room
-- forever. An `iCalUID` is identical across every occurrence of a series and
-- stays valid after somebody is removed from the invitation. So "knows the key"
-- and "is in the meeting" are different statements, and only the second one is
-- the permission.
--
-- The server can prove the second for itself only when the calendar reached it:
-- `calendar_events` is written by the sync under the service role and is not
-- client-writable. That covers Google Calendar through the broker and nothing
-- else — the macOS Calendars path reads EventKit on the device and never sends
-- it, which `20260815171500` describes as "the path most people already have".
-- Requiring server-side calendar proof outright would therefore remove the
-- feature from most of the people who use it.
--
-- So: prove it where the server can, and ask the host where it cannot. A join
-- with matching calendar evidence behaves exactly as it does today. A join
-- without it creates a `pending` row that no policy accepts, and the host — who
-- can see the participant list in the call and is the only party who actually
-- knows who is in the room — approves or denies it.

-- ── The state a listener is in ──────────────────────────────────────────────

-- `joined` by default so every row that exists today keeps the access it has;
-- the functions below always write it explicitly.
alter table public.room_listeners
    add column status text not null default 'joined'
        check (status in ('pending', 'joined', 'denied'));

-- ── What the server can check for itself ────────────────────────────────────

-- The caller's own calendar, covering now, carrying the identity they claim.
--
-- The same ten minutes of slack `_calendar_identity_at` uses, and for the same
-- reason: people join before the hour and start recording after it. Unlike that
-- function this asks about a specific identity rather than picking the nearest
-- entry, because somebody with two overlapping invitations is in both.
--
-- `room_key` is derived here rather than read: `20260815143012` dropped the
-- stored column from this table, having found nothing that filtered on it. The
-- window is bounded by `calendar_events_upcoming_idx (user_id, starts_at)` and
-- the key is compared over the handful of rows that survive it, so the parse
-- stays off the hot path.
create function public._calendar_proves_attendance(p_user uuid, p_ical text, p_room text)
    returns boolean
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select exists (
        select 1
          from public.calendar_events e
         where e.user_id = p_user
           and e.starts_at <= now() + interval '10 minutes'
           and coalesce(e.ends_at, e.starts_at + interval '1 hour') >= now() - interval '10 minutes'
           and (
                (p_ical is not null and e.ical_uid = p_ical)
                or (p_room is not null and public.conference_room_key(e.conference_url) = p_room)
           )
    );
$$;

revoke all on function public._calendar_proves_attendance(uuid, text, text) from public, anon, authenticated;

-- ── Joining ─────────────────────────────────────────────────────────────────

-- Dropped rather than replaced: the result gains `status`, and Postgres will not
-- change a function's return type in place. Nothing references it but the
-- clients, and the grant below restores what the drop takes away.
drop function public.join_live_room(text, text);

create function public.join_live_room(
    p_ical_uid text default null,
    p_conference_url text default null
)
    returns table (
        listener_id uuid,
        host_name text,
        host_meeting_id uuid,
        started_at timestamptz,
        status text
    )
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_room   text := public.conference_room_key(p_conference_url);
    v_ical   text := nullif(btrim(coalesce(p_ical_uid, '')), '');
    v_org    uuid;
    v_host   public.meeting_start_leases;
    v_id     uuid;
    v_status text;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if v_ical is null and v_room is null then
        return;
    end if;

    select active_org_id into v_org from public.profiles where user_id = auth.uid();
    if v_org is null then
        return;
    end if;

    v_host := public._live_lease_in_org(v_org, v_ical, v_room, auth.uid());
    if v_host.meeting_id is null then
        return;
    end if;

    -- Against the host's lease, never against what the caller sent. Both this
    -- and `_live_lease_in_org` match on "invitation **or** room", so a caller
    -- who supplies the victim's conference URL *and* their own unrelated
    -- invitation satisfies the two halves with two different keys: the room
    -- finds the host, the invitation finds the caller's own calendar, and
    -- nothing ever checks that they are the same meeting. The lease's keys are
    -- stamped by `_stamp_lease_identity` from the host's own calendar, so
    -- asking the caller's calendar about *those* is the question that was meant:
    -- "is the meeting they are recording also on your calendar, right now".
    v_status := case
        when public._calendar_proves_attendance(auth.uid(), v_host.ical_uid, v_host.room_key)
            then 'joined'
        else 'pending'
    end;

    insert into public.room_listeners (host_meeting_id, listener_user_id, org_id, status)
    values (v_host.meeting_id, auth.uid(), v_org, v_status)
    on conflict do nothing
    returning id into v_id;

    if v_id is null then
        select rl.id, rl.status into v_id, v_status
          from public.room_listeners rl
         where rl.host_meeting_id = v_host.meeting_id
           and rl.listener_user_id = auth.uid()
           and rl.left_at is null;
    end if;

    -- The host learns immediately, because being listened to without knowing is
    -- the one outcome this feature must never produce — and when the request is
    -- pending, this notification is how they are asked.
    perform public._notify_access_changed('user:' || v_host.user_id::text);

    return query
    select v_id, public._display_name(v_host.user_id), v_host.meeting_id, v_host.granted_at, v_status;
end;
$$;

revoke all on function public.join_live_room(text, text) from public, anon;
grant execute on function public.join_live_room(text, text) to authenticated;

-- ── The host answers ────────────────────────────────────────────────────────

-- Only the person recording decides. `meeting_start_leases` is the record of who
-- that is, and it is not client-writable.
create function public._assert_is_host(p_listener uuid)
    returns public.room_listeners
    language plpgsql
    stable
    security definer
    set search_path = ''
as $$
declare
    v_row public.room_listeners;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    select rl.* into v_row from public.room_listeners rl where rl.id = p_listener;
    if v_row.id is null then
        raise exception 'no such listener' using errcode = '42704';
    end if;
    if not exists (
        select 1 from public.meeting_start_leases l
         where l.meeting_id = v_row.host_meeting_id and l.user_id = auth.uid()
    ) then
        raise exception 'that is not your meeting' using errcode = '42501';
    end if;

    return v_row;
end;
$$;

revoke all on function public._assert_is_host(uuid) from public, anon, authenticated;

create function public.approve_room_listener(p_listener uuid)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    perform public._assert_is_host(p_listener);

    update public.room_listeners
       set status = 'joined'
     where id = p_listener and status = 'pending' and left_at is null;
end;
$$;

revoke all on function public.approve_room_listener(uuid) from public, anon;
grant execute on function public.approve_room_listener(uuid) to authenticated;

-- Denying closes the row rather than parking it: the partial unique index is on
-- `left_at is null`, so a closed row is also what lets somebody ask again later
-- — from a meeting they are actually in, where the calendar answers for them.
create function public.deny_room_listener(p_listener uuid)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    perform public._assert_is_host(p_listener);

    update public.room_listeners
       set status = 'denied', left_at = now()
     where id = p_listener and left_at is null;
end;
$$;

revoke all on function public.deny_room_listener(uuid) from public, anon;
grant execute on function public.deny_room_listener(uuid) to authenticated;

-- ── What the host is shown ──────────────────────────────────────────────────

-- `room_listeners_of` keeps its shape and its meaning — who is listening — and
-- so now answers only for approved rows. The requests are a different question
-- and get their own function rather than a widened return type, which a released
-- client would not know how to decode.
create or replace function public.room_listeners_of(p_meeting uuid)
    returns table (listener_name text)
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if not exists (
        select 1 from public.meeting_start_leases l
         where l.meeting_id = p_meeting and l.user_id = auth.uid()
    ) then
        return;
    end if;

    return query
    select public._display_name(rl.listener_user_id)
      from public.room_listeners rl
     where rl.host_meeting_id = p_meeting
       and rl.left_at is null
       and rl.status = 'joined'
     order by rl.joined_at;
end;
$$;

create function public.pending_room_listeners(p_meeting uuid)
    returns table (listener_id uuid, listener_name text, asked_at timestamptz)
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if not exists (
        select 1 from public.meeting_start_leases l
         where l.meeting_id = p_meeting and l.user_id = auth.uid()
    ) then
        return;
    end if;

    return query
    select rl.id, public._display_name(rl.listener_user_id), rl.joined_at
      from public.room_listeners rl
     where rl.host_meeting_id = p_meeting
       and rl.left_at is null
       and rl.status = 'pending'
     order by rl.joined_at;
end;
$$;

revoke all on function public.pending_room_listeners(uuid) from public, anon;
grant execute on function public.pending_room_listeners(uuid) to authenticated;

-- ── Every read the status has to reach ──────────────────────────────────────

create or replace function public.is_live_room_listener(p_meeting uuid)
    returns boolean
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select exists (
        select 1
          from public.room_listeners rl
          join public.meeting_start_leases l on l.meeting_id = rl.host_meeting_id
          join public.org_members m
            on m.org_id = rl.org_id and m.user_id = rl.listener_user_id and m.status = 'active'
         where rl.host_meeting_id = p_meeting
           and rl.listener_user_id = (select auth.uid())
           and rl.left_at is null
           and rl.status = 'joined'
           and l.status = 'active'
           and coalesce(l.last_used_at, l.granted_at) > now() - interval '90 seconds'
    );
$$;

create or replace function public._live_rooms_i_listen_to()
    returns setof uuid
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select rl.host_meeting_id
      from public.room_listeners rl
      join public.meeting_start_leases l on l.meeting_id = rl.host_meeting_id
      join public.org_members m
        on m.org_id = rl.org_id and m.user_id = rl.listener_user_id and m.status = 'active'
     where rl.listener_user_id = (select auth.uid())
       and rl.left_at is null
       and rl.status = 'joined'
       and l.status = 'active'
       and coalesce(l.last_used_at, l.granted_at) > now() - interval '90 seconds';
$$;

-- ── The recap window ────────────────────────────────────────────────────────
--
-- The meeting row is reached by neither function above, and its policy was
-- written inline — which is also why it has never granted anything. A policy's
-- own subquery runs under the caller's RLS, and a listener cannot select the
-- host's `meeting_start_leases` row: the table is revoked from `authenticated`
-- and its policies are owner-only. So the join it depends on returns nothing and
-- the predicate is false for exactly the people it exists for. That is the same
-- trap `_live_rooms_i_listen_to` was extracted to avoid, and `20260815214500`
-- named it in advance: "two copies of a liveness rule is how one of them ends up
-- outliving the other."
--
-- Through a definer function, so the rule is asked once and can see what it has
-- to see, and with the checks its siblings make — not left, still a member,
-- approved — which the inline copy also dropped.
create function public._rooms_i_listened_to_recently()
    returns setof uuid
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select rl.host_meeting_id
      from public.room_listeners rl
      join public.meeting_start_leases l on l.meeting_id = rl.host_meeting_id
      join public.org_members m
        on m.org_id = rl.org_id and m.user_id = rl.listener_user_id and m.status = 'active'
     where rl.listener_user_id = (select auth.uid())
       and rl.left_at is null
       and rl.status = 'joined'
       and coalesce(l.ended_at, l.last_used_at, l.granted_at) > now() - interval '15 minutes';
$$;

revoke all on function public._rooms_i_listened_to_recently() from public, anon;
grant execute on function public._rooms_i_listened_to_recently() to authenticated;

alter policy "listeners read the meeting they just listened to" on public.meetings
    using (deleted_at is null and meetings.id in (select public._rooms_i_listened_to_recently()));
