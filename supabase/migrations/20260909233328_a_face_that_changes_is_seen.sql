-- An organization's own row changes on somebody else's Mac, and nobody hears.
--
-- `20260815100636` pushes when permission moves and `20260828105745` when a
-- session does. Between them sits the row that decides what the organization
-- *looks* like — its name and its logo — and no trigger has ever watched it. An
-- admin sets a logo and every colleague keeps drawing the monogram until their
-- app happens to refresh for some other reason: a sign-in, a context switch, a
-- poke about something unrelated. The row was correct on the server the whole
-- time; only the windows disagreed.
--
-- The audience is `org:<id>` and only that. Everyone who can see the name is an
-- active member, which is exactly who that topic's policy admits, and the mark
-- is public by design (`20260818223500`) — so the poke tells nobody anything a
-- query of theirs would not.
--
-- Two columns, not every update. `logo_path` and `name` are what other people
-- draw. `deleted_at` is deliberately absent: deleting an organization cascades
-- through the memberships, and `20260815104417` already tells each member on
-- their own `user:` topic — the topic that survives losing the membership,
-- which an `org:` message could not.
--
-- Deploy order and rollback. Additive and one-sided: a client that never
-- subscribes never hears this, and one that does runs the refresh it already
-- runs on every other poke. Apply before or after any client ships; roll back
-- by dropping the two objects below. Nothing depends on the poke arriving —
-- the ordinary refresh still catches up — so there is no retirement gate and no
-- legacy path to remove later.

do $$
begin
    if to_regprocedure('public._notify_access_changed(text)') is null then
        raise exception
            'access broadcasting is not set up on this branch: apply 20260815100636 first';
    end if;
end $$;

-- The send sits in an inner block with the handler, and the function body's
-- outer block has none — same shape and same reason as
-- `_broadcast_meeting_change`: PL/pgSQL allocates a subtransaction on entry to
-- any block carrying an exception clause, so a handler wrapping the whole body
-- would charge a subxid to every organization row touched by a bulk update.
create function public._broadcast_org_change()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
begin
    begin
        perform public._notify_access_changed('org:' || new.id::text);
    exception when others then
        -- Loud but not fatal. Renaming an organization must not fail because
        -- the message about it could not be sent, and a silently dead
        -- broadcast is indistinguishable from one nobody needed.
        raise warning 'broadcast_org_change failed: %', sqlerrm;
    end;
    return null;
end;
$$;

revoke all on function public._broadcast_org_change() from public, anon, authenticated, service_role;

create trigger broadcast_access after update on public.organizations
    for each row
    when (
        old.logo_path is distinct from new.logo_path
        or old.name is distinct from new.name
    )
    execute function public._broadcast_org_change();
