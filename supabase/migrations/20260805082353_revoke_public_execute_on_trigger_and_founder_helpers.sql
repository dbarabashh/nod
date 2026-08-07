revoke all on function public.handle_new_user_profile()      from public, anon, authenticated;
revoke all on function public.handle_new_user_subscription() from public, anon, authenticated;
revoke all on function public.touch_knowledge_thread()       from public, anon, authenticated;

revoke all on function public.is_founder()      from public, anon;
revoke all on function public._assert_founder() from public, anon;

grant execute on function public.is_founder()      to authenticated;
grant execute on function public._assert_founder() to authenticated;;
