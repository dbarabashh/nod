-- `_team_membership_grants_content(team, user)` takes an arbitrary user and
-- answers whether that membership carries content, and it was executable by
-- any signed-in account. Every caller is a SECURITY DEFINER function owned by
-- postgres, so nothing on the client path loses access when the grant goes.

revoke execute on function public._team_membership_grants_content(uuid, uuid) from public, anon, authenticated;
grant execute on function public._team_membership_grants_content(uuid, uuid) to service_role;
