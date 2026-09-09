-- What the person listening sees.
--
-- Joining a colleague's recording currently buys one thing: their transcript,
-- as a wall of text. That is the opposite of the point. Somebody who arrives
-- late wants what it amounted to, wants to ask their own question about it, and
-- wants the notes the meeting is producing — the same three things the person
-- recording it has, minus the ability to end it.
--
-- Two of those need the server, and this is both:
--
--   * the live findings, so "Notes" says the same thing on both machines rather
--     than each side running its own pass and quietly disagreeing about what
--     the room decided;
--   * the finished meeting, so pressing End on one Mac turns into a summary on
--     the other instead of the read simply going dark.
--
-- `LiveFinding` explains at length why findings were kept in memory: the
-- meeting row did not reach the server until the recording ended, so a finding
-- had nothing to hang off. Streaming changed that and the comment did not — the
-- row is upserted at the first chunk, which is the whole reason a listener can
-- read the transcript at all. The foreign key below is therefore safe today in
-- a way it genuinely was not when that comment was written.

create table public.meeting_live_findings (
    meeting_id  uuid        not null references public.meetings(id) on delete cascade,
    -- The finding's own id, minted on the host and stable across its life, so a
    -- finding that is later superseded updates rather than duplicating.
    id          uuid        not null,
    kind        text        not null,
    tier        text        not null check (tier in ('strict', 'soft')),
    text        text        not null,
    -- A deadline as it was said out loud ("by Friday"), when one was.
    deadline    text,
    -- When the line was said, as against when the pass noticed it. Both, because
    -- the gap between them is what makes a notice read as stale, and a listener
    -- looking at the same note deserves the same staleness the host sees.
    spoken_at   timestamptz,
    found_at    timestamptz not null,
    state       text        not null check (state in ('standing', 'superseded', 'dismissed')),
    revision_of uuid,
    updated_at  timestamptz not null default now(),
    primary key (meeting_id, id)
);

-- `LiveFinding.evidenceIdx` is deliberately not here. It indexes the host's own
-- `TranscriptStore`, and the one thing a listener could do with a transcript
-- offset is read the transcript — which is the half of this they said they did
-- not want and the half the privacy rule is built around keeping live-only.

create index meeting_live_findings_standing_idx
    on public.meeting_live_findings (meeting_id) where state = 'standing';

alter table public.meeting_live_findings enable row level security;

-- The host owns them.
create policy "owners write their live findings"
    on public.meeting_live_findings for all to authenticated
    using (exists (
        select 1 from public.meetings m
        where m.id = meeting_id and m.user_id = (select auth.uid())
    ))
    with check (exists (
        select 1 from public.meetings m
        where m.id = meeting_id and m.user_id = (select auth.uid())
    ));

-- And a listener reads them for exactly as long as they may read the
-- transcript, through the same predicate rather than a second copy of the rule.
-- `20260815214500` made that a function precisely so the next surface would not
-- restate it and drift.
create policy "listeners read a live room's findings"
    on public.meeting_live_findings for select to authenticated
    using ((select public.is_live_room_listener(meeting_id)));

grant select, insert, update, delete on table public.meeting_live_findings to authenticated;

-- Findings are the *live* view and stop meaning anything once the meeting is
-- over — what survives is `action_items`, which the finalize writes with the
-- history intact. Dropping them with the recording keeps one answer to "what
-- did this meeting produce" rather than two that will eventually disagree.
create function public._drop_live_findings_when_meeting_ends()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    if new.status = 'ended' and old.status is distinct from 'ended' then
        delete from public.meeting_live_findings where meeting_id = new.meeting_id;
    end if;
    return null;
end;
$$;

revoke all on function public._drop_live_findings_when_meeting_ends() from public, anon, authenticated;

create trigger drop_live_findings
    after update of status on public.meeting_start_leases
    for each row execute function public._drop_live_findings_when_meeting_ends();

-- The trigger only fires on an explicit End. A host who force-quits mid-meeting
-- leaves the lease `active` and expired: nobody can read the findings any more
-- (`is_live_room_listener` checks the expiry, not just the status), but the rows
-- would sit there forever if that person never records again. A sweep, because
-- the crash case is exactly the one a client-side delete cannot cover.
do $$
begin
    perform cron.schedule(
        'purge-abandoned-live-findings',
        '17 4 * * *',
        $cmd$delete from public.meeting_live_findings f
             where not exists (
                 select 1 from public.meeting_start_leases l
                 where l.meeting_id = f.meeting_id
                   and l.status = 'active'
                   and l.expires_at > now()
             )$cmd$
    );
exception when others then
    raise notice 'cron.schedule unavailable (%) — abandoned findings will not be swept.', sqlerrm;
end $$;

-- ── The meeting, after it ends ──────────────────────────────────────────────
--
-- `20260815182000` set the rule that a listener's access lasts exactly as long
-- as the recording, and gave a good reason: nothing to clean up, nothing to
-- expire, the permission simply stops being true. That rule is kept for the
-- transcript, which is the sensitive half and which a listener said they do not
-- want anyway.
--
-- The meeting row is the other half, and stopping there was wrong in a way only
-- use showed. Somebody follows a call for twenty minutes, the host presses End,
-- and their screen goes blank at the exact moment the thing they stayed for —
-- the summary — is being written. Reading a recap of a conversation you sat
-- through is not a wider promise than having sat through it.
--
-- Narrow twice over. It widens `meetings` and nothing else — the transcript, the
-- chat, the screen text and the embeddings are governed by their own policies
-- and none of them mention `room_listeners`. And it is bounded in time: the
-- client waits three minutes for the recap and then gives up, so a grant with no
-- end would hand somebody who listened for thirty seconds a permanent read of a
-- meeting they were never given. The window below is that wait, with room for a
-- slow recap, and nothing more.
create policy "listeners read the meeting they just listened to"
    on public.meetings for select to authenticated
    using (deleted_at is null and exists (
        select 1
        from public.room_listeners rl
        join public.meeting_start_leases l on l.meeting_id = rl.host_meeting_id
        where rl.host_meeting_id = meetings.id
          and rl.listener_user_id = (select auth.uid())
          and coalesce(l.ended_at, l.last_used_at, l.granted_at) > now() - interval '15 minutes'
    ));
