-- A team appearing, changing its name, or going away is an access change too.
--
-- `20260815100636` pushed on membership and on shares, which covers who can read
-- what. It left out the teams themselves, and that turned out to matter for a
-- reason that is only obvious once seen: the list of teams is what the sharing
-- menu offers. Create a team on one Mac and the person on the other cannot share
-- a folder with it — not because they lack permission, but because their copy of
-- the list predates it, and nothing told them to ask again.
--
-- Sent to the organization's topic rather than to each member: everyone in the
-- organization sees the same set of teams, so this is one message rather than
-- one per person.
--
-- `after` and returning null, like the triggers it joins: the write is the real
-- work, and `_notify_access_changed` swallows a failed send so a channel that is
-- down cannot take a rename with it.

create function public._broadcast_team_change()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_row public.teams := coalesce(new, old);
begin
    perform public._notify_access_changed('org:' || v_row.org_id::text);
    return null;
end;
$$;

revoke all on function public._broadcast_team_change() from public, anon, authenticated;

create trigger broadcast_access after insert or update or delete on public.teams
    for each row execute function public._broadcast_team_change();
