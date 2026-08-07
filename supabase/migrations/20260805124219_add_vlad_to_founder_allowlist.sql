-- `is_founder()` reads `_founder_emails()` since 20260805082210, so the dashboard
-- allowlist is one list in one place. `_excluded_emails()` is the separate list
-- that keeps internal accounts out of the product metrics — a new team member
-- belongs in both, or their own usage shows up as end-user activity.

create or replace function public._founder_emails()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['dmytro@hellonod.app', 'viktoriia@hellonod.app', 'vlad@hellonod.app'];
$$;
create or replace function public._excluded_emails()
returns text[]
language sql
immutable
as $$
  select array[
    'dmytro@hellonod.app',
    'viktoriia@hellonod.app',
    'vlad@hellonod.app',
    'dbarabashdev@gmail.com',
    'riwwom@gmail.com',
    'vvika.ps@gmail.com'
  ];
$$;
