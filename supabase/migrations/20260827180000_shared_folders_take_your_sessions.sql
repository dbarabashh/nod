-- A shared folder you can read is a folder you can file your own sessions in.
--
-- `meeting_labels` has required, since `20260603211050`, that the caller own
-- *both* the session and the label. That was written when Nod was
-- single-user, and its stated reason still holds for half of it: "so a
-- compromised JWT can't attach labels to another user's session."
--
-- `20260814152612` then added shared folders — and added only SELECT policies,
-- being careful to widen nothing else. So a folder shared with a team was
-- visible to everybody in it and writable by nobody but its owner: a teammate
-- could open the folder, see the sessions in it, and not put one of their own
-- there. That is not a folder anybody would call shared.
--
-- The half that stays is the half that matters. `m.user_id = auth.uid()` is
-- kept exactly as it was, so the only session you can ever file is your own.
-- Filing into a shared folder makes a session readable to everyone the folder
-- reaches (`can_read_meeting_via_folder`), which means writing here is an act
-- of disclosure — and you may only ever disclose what is yours. Filing somebody
-- *else's* session, which would re-share their recording with a group they
-- never gave it to, stays refused.
--
-- No role on the share, deliberately. Read and contribute are one permission
-- here, as they are in a chat channel: being in it means you can post to it.
-- The split Drive and Notion make exists because their containers hold objects
-- a viewer could otherwise edit; a folder here holds links to sessions nobody
-- but the owner can change. A `viewer`/`contributor` column would be a
-- vocabulary with no second word yet and a settings screen to design before
-- anybody could say it.
--
-- Safe to change in place rather than through a compatibility window: neither
-- `folder_shares` nor these policies exist in production — folder sharing is a
-- sandbox-only feature — so no released client and no already-granted share
-- has its meaning changed underneath it.

drop policy "users insert own meeting_labels" on public.meeting_labels;

create policy "file your own sessions in folders you can reach"
    on public.meeting_labels for insert to authenticated
    with check (
        (select auth.uid()) = user_id
        and exists (
            select 1 from public.meetings m
             where m.id = meeting_id and m.user_id = (select auth.uid())
        )
        and (
            exists (
                select 1 from public.labels l
                 where l.id = label_id and l.user_id = (select auth.uid())
            )
            or (select public.can_read_folder(label_id))
        )
    );

-- Unfiling follows who is affected, not who typed it.
--
-- Only the person who filed a session could remove it, which left the owner of
-- a shared folder unable to take anything out of their own folder — and now
-- that teammates can put things in, that would be a folder its owner cannot
-- curate. Owning the folder is the second way in; owning the session is not,
-- because removing your session from somebody's folder is done by removing your
-- own link to it, which the first clause already allows.
drop policy "users delete own meeting_labels" on public.meeting_labels;

create policy "unfile your own links, or anything in your folder"
    on public.meeting_labels for delete to authenticated
    using (
        (select auth.uid()) = user_id
        or exists (
            select 1 from public.labels l
             where l.id = label_id and l.user_id = (select auth.uid())
        )
    );
