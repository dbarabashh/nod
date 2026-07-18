
create table if not exists public.founder_hypotheses (
  id uuid primary key default gen_random_uuid(),
  statement text not null,
  rationale text,
  status text not null default 'untested'
    check (status in ('untested', 'confirmed', 'refuted')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by text
);

create table if not exists public.founder_user_notes (
  user_id uuid primary key references auth.users(id) on delete cascade,
  who_they_are text,
  how_they_work text,
  why_chose text,
  requested text,
  last_feedback text,
  updated_at timestamptz not null default now(),
  updated_by text
);

create table if not exists public.founder_manual_inputs (
  singleton boolean primary key default true check (singleton),
  marketing_spend_usd numeric default 0,
  spend_period text,
  assumed_lifetime_months int default 12,
  updated_at timestamptz not null default now(),
  updated_by text
);
insert into public.founder_manual_inputs (singleton) values (true)
  on conflict (singleton) do nothing;

alter table public.founder_hypotheses enable row level security;
alter table public.founder_user_notes enable row level security;
alter table public.founder_manual_inputs enable row level security;

drop policy if exists founder_all on public.founder_hypotheses;
create policy founder_all on public.founder_hypotheses
  for all to authenticated using (public.is_founder()) with check (public.is_founder());

drop policy if exists founder_all on public.founder_user_notes;
create policy founder_all on public.founder_user_notes
  for all to authenticated using (public.is_founder()) with check (public.is_founder());

drop policy if exists founder_all on public.founder_manual_inputs;
create policy founder_all on public.founder_manual_inputs
  for all to authenticated using (public.is_founder()) with check (public.is_founder());

create or replace function public.founder_user_notes_view()
returns table (
  user_id uuid, email text, display_name text, created_at timestamptz,
  plan text, sub_status text, meetings_count bigint, last_active_at timestamptz,
  who_they_are text, how_they_work text, why_chose text, requested text,
  last_feedback text, updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, auth
as $$
begin
  perform public._assert_founder();
  return query
  select
    u.id, u.email::text, p.display_name, u.created_at,
    s.plan, s.status,
    (select count(*) from meetings m where m.user_id = u.id and m.deleted_at is null),
    greatest(p.last_seen_at, u.last_sign_in_at, (select max(ue.created_at) from usage_events ue where ue.user_id = u.id)),
    n.who_they_are, n.how_they_work, n.why_chose, n.requested, n.last_feedback, n.updated_at
  from auth.users u
  left join profiles p on p.user_id = u.id
  left join subscriptions s on s.user_id = u.id
  left join founder_user_notes n on n.user_id = u.id
  where lower(u.email) <> all(public._excluded_emails())
  order by (n.updated_at is null), n.updated_at desc nulls last, u.created_at desc;
end;
$$;

insert into public.founder_hypotheses (statement, rationale, status)
select * from (values
  ('Users who run 5+ meetings in their first 3 days are more likely to convert to paid',
   'Early depth of use signals the product clicked; worth checking against conversions.', 'untested'),
  ('Users who share a meeting summary retain better than those who never share',
   'Sharing pulls in collaborators and creates external pull to keep using Nod.', 'untested'),
  ('Trying AI chat in the first session correlates with higher week-1 retention',
   'Chat is a core aha moment; using it early may cement the habit.', 'untested')
) as v(statement, rationale, status)
where not exists (select 1 from public.founder_hypotheses);
