
create or replace function public.founder_acquisition()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  result jsonb;
  excl_emails text[] := public._excluded_emails();
  excl uuid[] := public._excluded_user_ids();
  total_users bigint;
begin
  perform public._assert_founder();
  select count(*) into total_users from auth.users where lower(email) <> all(excl_emails);

  select jsonb_build_object(
    'total_users', total_users,
    'new_users_7d', (select count(*) from auth.users where lower(email) <> all(excl_emails) and created_at > now() - interval '7 days'),
    'new_users_30d', (select count(*) from auth.users where lower(email) <> all(excl_emails) and created_at > now() - interval '30 days'),
    'new_users_prev_7d', (select count(*) from auth.users where lower(email) <> all(excl_emails)
      and created_at > now() - interval '14 days' and created_at <= now() - interval '7 days'),
    'referred_users', (select count(distinct r.referee_user_id) from referrals r
      join auth.users u on u.id = r.referee_user_id where lower(u.email) <> all(excl_emails)),
    'organic_users', total_users - (select count(distinct r.referee_user_id) from referrals r
      join auth.users u on u.id = r.referee_user_id where lower(u.email) <> all(excl_emails)),
    -- signup → first meeting: distinct users who have recorded at least one meeting.
    -- Named distinctly from founder_activation.activated_users (the 2-in-3d bar).
    'users_with_meeting', (select count(distinct m.user_id) from meetings m
      where m.deleted_at is null and m.user_id <> all(excl)),
    'signup_to_meeting_pct', (
      select case when total_users = 0 then 0 else round(
        (select count(distinct m.user_id) from meetings m where m.deleted_at is null and m.user_id <> all(excl))
        * 100.0 / total_users, 1) end),
    'median_hours_to_first_meeting', (
      select round(coalesce(percentile_cont(0.5) within group (order by h), 0)::numeric, 1) from (
        select extract(epoch from (min(m.started_at) - u.created_at)) / 3600.0 as h
        from auth.users u join meetings m on m.user_id = u.id and m.deleted_at is null
        where lower(u.email) <> all(excl_emails)
        group by u.id, u.created_at
        having extract(epoch from (min(m.started_at) - u.created_at)) >= 0
      ) t),
    'generated_at', now()
  ) into result;
  return result;
end;
$$;
