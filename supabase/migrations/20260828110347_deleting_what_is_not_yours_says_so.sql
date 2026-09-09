-- Deleting somebody else's session told you it worked.
--
-- `soft_delete_meeting` has been, since `20260524111602`, a bare `language sql`
-- update scoped to `user_id = auth.uid()`. On your own session that is right.
-- On a session that reached you through a shared folder it matches zero rows,
-- and a `returns void` SQL function that changed nothing is indistinguishable
-- from one that did everything asked: PostgREST answers 204, the client removes
-- the row, and the person watching believes it is gone.
--
-- It comes back. Not at once — the list is cached — but on the next refresh, or
-- immediately on their other device, which is how this was found. The row was
-- never deleted; only the window agreed that it had been.
--
-- The reason the shape held this long is that it was written when Nod was
-- single-user (`20260523204132`), where "not yours" could not happen. Folder
-- sharing (`20260814152612`) made every list able to contain rows the caller
-- may read and may not change, and nothing revisited the writes.
--
-- Silence stays where silence is right. Deleting a session already in your
-- trash still succeeds: it is your session, the end state is the one you asked
-- for, and the durable outbox retries a completed delete after a crash — an
-- error there would turn a no-op into a stuck queue. Only "this is not yours"
-- raises, because that is the case where the caller's belief about what
-- happened is wrong.
--
-- `42501` (insufficient_privilege), matching every other refusal in this schema
-- (`grant_meeting`, `share_folder`, `revoke_meeting_grant`), so a client can
-- tell a permission refusal from a network failure without parsing prose.
--
-- Security invoker throughout. RLS is still what decides; this only reports
-- what RLS did. The `exists` probe reads under the caller's own policies, so it
-- cannot confirm the existence of a session they could not already select.
--
-- Deploy order and rollback. The behavior change is confined to a call that
-- previously did nothing: every caller acting on its own session is byte-for-
-- byte unaffected, so this may land before or after any client. A released
-- client that deletes a shared session now surfaces an error where it used to
-- show a lie — which is the fix, not a regression. Roll back by restoring the
-- `20260524111602` bodies.

create or replace function public.soft_delete_meeting(meeting_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
    v_rows int;
begin
    update public.meetings
       set deleted_at = now()
     where id = meeting_id
       and user_id = auth.uid()
       and deleted_at is null;
    get diagnostics v_rows = row_count;
    if v_rows > 0 then
        return;
    end if;

    -- Yours, and already in the trash. The caller asked for a state it is
    -- already in.
    if exists (
        select 1 from public.meetings
         where id = meeting_id and user_id = auth.uid()
    ) then
        return;
    end if;

    raise exception 'that session is not yours to delete' using errcode = '42501';
end;
$$;

create or replace function public.restore_meeting(meeting_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
    v_rows int;
begin
    update public.meetings
       set deleted_at = null
     where id = meeting_id
       and user_id = auth.uid()
       and deleted_at is not null;
    get diagnostics v_rows = row_count;
    if v_rows > 0 then
        return;
    end if;

    if exists (
        select 1 from public.meetings
         where id = meeting_id and user_id = auth.uid()
    ) then
        return;
    end if;

    raise exception 'that session is not yours to restore' using errcode = '42501';
end;
$$;

-- Restated because `create or replace` keeps the old privileges only when the
-- function already existed with exactly this signature, and the schema's
-- default privileges have granted nothing since `20260805082210`.
revoke all on function public.soft_delete_meeting(uuid) from public, anon;
revoke all on function public.restore_meeting(uuid) from public, anon;
grant execute on function public.soft_delete_meeting(uuid) to authenticated;
grant execute on function public.restore_meeting(uuid) to authenticated;
