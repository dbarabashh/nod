-- Listening to a colleague's meeting while it is still happening.
--
-- Somebody who joins a call fifteen minutes late has missed the part that
-- explains the rest of it, and a colleague in the same organization is already
-- transcribing exactly that. This is the read that lets them catch up without
-- starting a second recording of the same room.
--
-- The whole design is one sentence: **access lasts exactly as long as the
-- recording does**. Not a TTL somebody has to remember to set, not a sweep that
-- can fall behind — the policy asks the lease, and the lease is what already
-- knows whether audio is still arriving. The host presses End and `status`
-- becomes 'ended'; their Mac dies and `last_used_at` goes stale in ninety
-- seconds. Either way the read closes on its own, with nothing to clean up.
--
-- Ninety seconds and not some new number, because that is already what
-- `start_meeting_lease` uses to decide a lease has been abandoned. A second
-- staleness rule would eventually disagree with the first.
--
-- Read-only, and only the transcript. A listener never writes into the host's
-- rows: two people mutating one meeting is a class of conflict this model does
-- not have anywhere else, and joining a call is not a reason to introduce it.

create table public.room_listeners (
    id               uuid primary key default gen_random_uuid(),
    host_meeting_id  uuid not null,
    listener_user_id uuid not null references auth.users(id) on delete cascade,
    org_id           uuid not null references public.organizations(id) on delete cascade,
    joined_at        timestamptz not null default now(),
    left_at          timestamptz
);

-- One live listening row per person per room. Leaving sets `left_at`, so the
-- partial index lets somebody re-join later without tripping over their own
-- earlier visit.
create unique index room_listeners_live_idx
    on public.room_listeners (host_meeting_id, listener_user_id)
    where left_at is null;

-- The policy below asks "is this meeting one I am listening to", which is the
-- other direction.
create index room_listeners_by_listener_idx
    on public.room_listeners (listener_user_id, host_meeting_id) where left_at is null;

alter table public.room_listeners enable row level security;

-- You can see that you are listening, and a host can see who is listening to
-- them. Nothing here is writable from a client: joining and leaving go through
-- the functions in the next migration, which are the only place the org and the
-- room identity are checked.
create policy "listeners read their own row"
    on public.room_listeners
    for select to authenticated
    using ((select auth.uid()) = listener_user_id);

create policy "hosts read who is listening"
    on public.room_listeners
    for select to authenticated
    using (
        exists (
            select 1 from public.meeting_start_leases l
             where l.meeting_id = room_listeners.host_meeting_id
               and l.user_id = (select auth.uid())
        )
    );

-- ── The read this all exists for ────────────────────────────────────────────

-- Whether the caller is listening to a meeting that is still being recorded.
--
-- A function rather than an inlined `exists` so the rule has one home: the same
-- test gates the transcript rows and, in the next migration, the channel that
-- says new ones arrived. Two copies of a liveness rule is how one of them ends
-- up outliving the other.
create function public.is_live_room_listener(p_meeting uuid)
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
           and l.status = 'active'
           and coalesce(l.last_used_at, l.granted_at) > now() - interval '90 seconds'
    );
$$;

revoke all on function public.is_live_room_listener(uuid) from public, anon;
grant execute on function public.is_live_room_listener(uuid) to authenticated;

-- Permissive, so it adds to what a person can already read rather than
-- narrowing it. Every row of the meeting, not only those written after joining:
-- arriving late is the entire case this serves, and a transcript that starts at
-- the moment you walked in explains nothing.
create policy "listeners read a live room's transcript"
    on public.meeting_transcripts
    for select to authenticated
    using ((select public.is_live_room_listener(meeting_transcripts.meeting_id)));
