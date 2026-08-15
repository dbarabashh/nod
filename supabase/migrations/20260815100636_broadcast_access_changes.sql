-- Telling people their access changed, at the moment it changes.
--
-- Until now nothing pushed: the app learned about a folder it had lost only by
-- asking again, so a project stayed in somebody's sidebar until they switched
-- windows. The fix is a message, and the shape of that message is the whole
-- design decision here.
--
-- Broadcast, not Postgres Changes. Two reasons, both from the documentation
-- rather than taste:
--
--   * "RLS policies are not applied to DELETE statements" — so a subscription to
--     `folder_shares` would deliver every unshare in the system to every
--     subscriber. No data leaks (the payload is a primary key), but every client
--     wakes for every other organization's changes.
--   * "Postgres Changes authorizes every event against each subscriber… a single
--     change to a table with 100 subscribed users performs 100 authorization
--     checks", and RLS-filtered subscriptions run at roughly a tenth of the
--     throughput. The cost scales with who is listening rather than with what
--     happened.
--
-- Broadcast inverts that: the trigger decides who is affected and sends there.
--
-- Two kinds of topic, because the two kinds of change have different audiences:
--
--   `user:<uuid>`  — your membership changed. Sent to you personally, and this
--                    is the one that has to survive revocation: you pass the
--                    policy on your own topic whether or not you are still in
--                    the organization, which is exactly the moment you need to
--                    hear from us.
--   `org:<uuid>`   — a folder was shared or unshared with a whole organization.
--   `team:<uuid>`  — the same, for one team.
--
-- Audience topics keep the cost of a share change at one message rather than one
-- per member; membership topics keep revocation deliverable. Neither carries the
-- change itself — the payload says only that something moved, and the client
-- re-asks under its own permissions. Nothing readable travels through a channel.

-- ── Who may listen ──────────────────────────────────────────────────────────

-- `realtime.messages` is shared infrastructure, so the policy is written to
-- match one topic exactly rather than to describe a family of them.
create policy "receive access changes for yourself and your audiences"
    on realtime.messages
    for select
    to authenticated
    using (
        realtime.messages.extension = 'broadcast'
        and (
            realtime.topic() = 'user:' || (select auth.uid())::text
            or exists (
                select 1 from public.org_members m
                where m.user_id = (select auth.uid())
                  and m.status = 'active'
                  and realtime.topic() = 'org:' || m.org_id::text
            )
            or exists (
                select 1
                from public.team_members tm
                join public.teams t on t.id = tm.team_id and t.deleted_at is null
                join public.org_members m
                  on m.org_id = t.org_id and m.user_id = tm.user_id and m.status = 'active'
                where tm.user_id = (select auth.uid())
                  and realtime.topic() = 'team:' || tm.team_id::text
            )
        )
    );

-- ── Sending ─────────────────────────────────────────────────────────────────

-- One place, so every trigger below sends the same contentless shape and a
-- future sender cannot accidentally put a row in the payload.
create function public._notify_access_changed(p_topic text)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    perform realtime.send(
        jsonb_build_object('changed', true),
        'access',
        p_topic,
        true
    );
exception when others then
    -- A poke that cannot be sent must never take the transaction with it. The
    -- write that triggered it is the real work; this is only how somebody finds
    -- out sooner, and the app still asks again on its own.
    null;
end;
$$;

revoke all on function public._notify_access_changed(text) from public, anon, authenticated;

create function public._broadcast_share_change()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_row public.folder_shares := coalesce(new, old);
begin
    if v_row.team_id is not null then
        perform public._notify_access_changed('team:' || v_row.team_id::text);
    else
        perform public._notify_access_changed('org:' || v_row.org_id::text);
    end if;
    return null;
end;
$$;

create function public._broadcast_membership_change()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_user uuid := coalesce(new.user_id, old.user_id);
begin
    -- The person themselves, on the one topic they can always read. A colleague
    -- learning that the roster moved is a different question, answered when they
    -- open the settings pane that shows it.
    perform public._notify_access_changed('user:' || v_user::text);
    return null;
end;
$$;

revoke all on function public._broadcast_share_change() from public, anon, authenticated;
revoke all on function public._broadcast_membership_change() from public, anon, authenticated;

create trigger broadcast_access after insert or delete on public.folder_shares
    for each row execute function public._broadcast_share_change();

create trigger broadcast_access after insert or update or delete on public.org_members
    for each row execute function public._broadcast_membership_change();

create trigger broadcast_access after insert or delete on public.team_members
    for each row execute function public._broadcast_membership_change();
