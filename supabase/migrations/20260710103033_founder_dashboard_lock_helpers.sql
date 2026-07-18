
-- Internal helpers: called only from within SECURITY DEFINER functions (which run
-- as owner), so no external role needs EXECUTE. Lock them off the public API.
revoke all on function public._excluded_user_ids() from public, anon, authenticated;
revoke all on function public._excluded_emails() from public, anon;
revoke all on function public._founder_emails() from public, anon;

-- Pin search_path on the new immutable helper as defense in depth.
alter function public._excluded_emails() set search_path = public;
