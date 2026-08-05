-- Supabase's default privileges grant EXECUTE on every new function in `public`
-- to `anon` and `authenticated`. The `revoke all ... from public` that ships next
-- to each SECURITY DEFINER function never undid that — PUBLIC is a different
-- grantee — so every one of them has been reachable by `anon` since it landed.
-- Nothing leaked: each re-checks `auth.uid()` and bails. The default is the bug,
-- not the functions: the next one written without a guard is public on creation.
--
-- After this, a new function in `public` is callable by nobody until its own
-- migration grants it. Adding `grant execute ... to authenticated` is now part of
-- shipping a function, not an optional extra.

alter default privileges in schema public revoke execute on functions from anon, authenticated;

revoke all on function public.create_meeting_share(uuid)          from anon;
revoke all on function public.create_connection(text, text, text) from anon;
revoke all on function public.revoke_meeting_share(uuid)          from anon;
revoke all on function public.revoke_connection(uuid)             from anon;

-- A trigger function's EXECUTE is checked when the trigger is created, never when
-- it fires, so revoking it here leaves every existing trigger working.
revoke all on function public.handle_new_user_profile()      from anon, authenticated;
revoke all on function public.handle_new_user_subscription() from anon, authenticated;
revoke all on function public.touch_knowledge_thread()       from anon, authenticated;

-- `is_founder()` gates every founder RPC and `_founder_emails()` excludes the same
-- people from the metrics those RPCs read. They held two copies of one list, which
-- drift apart the first time someone is added to only one of them.
create or replace function public.is_founder()
returns boolean
language sql
stable
set search_path = ''
as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) = any (public._founder_emails());
$$;

-- `is_founder()` runs as its invoker, so the caller needs EXECUTE on the list it
-- now reads — including inside the founder RLS policies.
grant execute on function public._founder_emails() to authenticated;
