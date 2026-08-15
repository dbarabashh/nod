-- Noticing that a colleague is already recording this meeting.
--
-- The obvious shape is a new "claims" table written when a recording starts and
-- heartbeated while it runs. That table already exists: `meeting_start_leases`
-- is created by `start_meeting_lease`, its `last_used_at` is touched by every
-- transcription chunk through `validate_meeting_lease`, and it already treats
-- 90 seconds without a chunk as abandoned. A second record of "a recording is
-- happening" would only be a second thing to keep in step with the first.
--
-- So the lease gains what it was missing: which organization the recording
-- belongs to, and which meeting in the world it is.
--
-- Identity is decided **once**, here, at the moment recording starts — and the
-- finished `meetings` row inherits it from the lease rather than deriving it
-- again. Two derivations of one key is how a Zoom link normalized slightly
-- differently on two paths stops matching and nobody can tell that from "no
-- colleague recorded this".
--
-- Nothing here blocks anything. The answer is a suggestion the person can
-- ignore: wanting your own recording of a meeting somebody else is also
-- recording is a legitimate thing to want.

alter table public.meeting_start_leases
    add column org_id   uuid references public.organizations(id) on delete set null,
    add column ical_uid text,
    add column room_key text;

-- The lookup this is all for: another live recording, in my organization, of the
-- meeting I am in. Partial because a lease without identity — no calendar
-- connected, no invitation — can never match one.
create index meeting_start_leases_identity_idx
    on public.meeting_start_leases (org_id, status, last_used_at)
    where org_id is not null and (ical_uid is not null or room_key is not null);

-- ── What meeting is this ────────────────────────────────────────────────────

-- The calendar entry covering a moment, reduced to the two keys that identify it
-- across people.
--
-- Ten minutes of slack on each side: people join before the hour and start
-- recording after it, and an entry that has not quite begun is still the meeting
-- they are in.
create function public._calendar_identity_at(p_user uuid, p_at timestamptz)
    returns table (ical_uid text, room_key text, title text)
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select e.ical_uid,
           public.conference_room_key(e.conference_url),
           e.title
      from public.calendar_events e
     where e.user_id = p_user
       and e.starts_at <= p_at + interval '10 minutes'
       and coalesce(e.ends_at, e.starts_at + interval '1 hour') >= p_at - interval '10 minutes'
     order by abs(extract(epoch from (e.starts_at - p_at)))
     limit 1;
$$;

revoke all on function public._calendar_identity_at(uuid, timestamptz) from public, anon, authenticated;

-- ── Stamping the lease ──────────────────────────────────────────────────────

-- A trigger on the lease itself, rather than a call added to
-- `start_meeting_lease`. That function decides whether somebody may record at
-- all and is the one place billing depends on; identifying which meeting it is
-- has no business being edited into it.
create function public._stamp_lease_identity()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    select active_org_id into new.org_id
      from public.profiles where user_id = new.user_id;

    select i.ical_uid, i.room_key into new.ical_uid, new.room_key
      from public._calendar_identity_at(new.user_id, now()) i;

    return new;
end;
$$;

revoke all on function public._stamp_lease_identity() from public, anon, authenticated;

create trigger stamp_lease_identity
    before insert on public.meeting_start_leases
    for each row execute function public._stamp_lease_identity();

-- ── Who else is recording this ──────────────────────────────────────────────

-- A colleague's live recording of the same meeting, if there is one.
--
-- `security definer` because it reads leases that are not the caller's — but it
-- answers only inside the caller's own organization, only for a meeting they are
-- demonstrably in (their own lease carries the same key), and only with a name
-- and a start time. Never a meeting id, so nothing here can be turned into a
-- handle on somebody else's recording.
--
-- "Live" is the same 90 seconds `start_meeting_lease` already uses to decide a
-- lease is abandoned. A Mac that crashed mid-meeting stops being a reason to
-- tell the next person that somebody is recording.
create function public.concurrent_recording(p_meeting uuid)
    returns table (owner_name text, started_at timestamptz)
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_org  uuid;
    v_ical text;
    v_room text;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    select l.org_id, l.ical_uid, l.room_key
      into v_org, v_ical, v_room
      from public.meeting_start_leases l
     where l.meeting_id = p_meeting and l.user_id = auth.uid();
    if v_org is null or (v_ical is null and v_room is null) then
        return;
    end if;

    return query
    select coalesce(nullif(btrim(p.display_name), ''), split_part(u.email, '@', 1)),
           l.granted_at
      from public.meeting_start_leases l
      join public.org_members m
        on m.org_id = v_org and m.user_id = l.user_id and m.status = 'active'
      join auth.users u on u.id = l.user_id
      left join public.profiles p on p.user_id = l.user_id
     where l.org_id = v_org
       and l.user_id <> auth.uid()
       and l.status = 'active'
       and coalesce(l.last_used_at, l.granted_at) > now() - interval '90 seconds'
       and (
            (v_ical is not null and l.ical_uid = v_ical)
            or (v_room is not null and l.room_key = v_room)
       )
     order by l.granted_at
     limit 1;
end;
$$;

revoke all on function public.concurrent_recording(uuid) from public, anon;
grant execute on function public.concurrent_recording(uuid) to authenticated;

-- ── The finished meeting inherits it ────────────────────────────────────────

-- The identity was settled when recording started; deriving it again from the
-- calendar at insert time would be a second implementation that can disagree
-- with the first.
create function public._inherit_lease_identity()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    if new.ical_uid is null and new.room_key is null then
        select l.ical_uid, l.room_key into new.ical_uid, new.room_key
          from public.meeting_start_leases l
         where l.meeting_id = new.id and l.user_id = new.user_id;
    end if;
    return new;
end;
$$;

revoke all on function public._inherit_lease_identity() from public, anon, authenticated;

create trigger inherit_lease_identity
    before insert on public.meetings
    for each row execute function public._inherit_lease_identity();
