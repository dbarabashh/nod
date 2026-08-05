-- The previous migration revoked the `anon` grant that Supabase's default
-- privileges hand out, but these functions predate the `revoke ... from public`
-- boilerplate, so they still carried Postgres' own EXECUTE-to-PUBLIC grant —
-- which `anon` inherits. Revoking one without the other changes nothing.
--
-- Losing EXECUTE does not disarm a trigger: Postgres checks the privilege when
-- the trigger is created, never when it fires. Verified against this database
-- before shipping, since the blast radius is signup.

revoke all on function public.handle_new_user_profile()      from public, anon, authenticated;
revoke all on function public.handle_new_user_subscription() from public, anon, authenticated;
revoke all on function public.touch_knowledge_thread()       from public, anon, authenticated;

revoke all on function public.is_founder()      from public, anon;
revoke all on function public._assert_founder() from public, anon;

grant execute on function public.is_founder()      to authenticated;
grant execute on function public._assert_founder() to authenticated;
