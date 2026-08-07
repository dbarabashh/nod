alter default privileges in schema public revoke execute on functions from anon, authenticated;

revoke all on function public.create_meeting_share(uuid)          from anon;
revoke all on function public.create_connection(text, text, text) from anon;
revoke all on function public.revoke_meeting_share(uuid)          from anon;
revoke all on function public.revoke_connection(uuid)             from anon;

revoke all on function public.handle_new_user_profile()      from anon, authenticated;
revoke all on function public.handle_new_user_subscription() from anon, authenticated;
revoke all on function public.touch_knowledge_thread()       from anon, authenticated;

create or replace function public.is_founder()
returns boolean
language sql
stable
set search_path = ''
as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) = any (public._founder_emails());
$$;

grant execute on function public._founder_emails() to authenticated;;
