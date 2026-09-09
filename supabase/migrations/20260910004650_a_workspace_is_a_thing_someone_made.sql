-- Whether anyone is actually making a workspace, and whether it goes anywhere.
--
-- `organizations`, `org_members`, `org_invites` and `org_subscriptions` have
-- been writable for weeks and nothing on the founder dashboard reads any of
-- them. The first workspace was created on 2026-09-09 and nobody could see it.
--
-- Creating a workspace is not adoption. One person making a room they never
-- invite anyone into looks identical, in a `count(*)`, to a team that moved in.
-- So this returns the stages that tell those apart — invited, accepted, used,
-- paid — per workspace, and leaves the counting of how many reached each stage
-- to the page.
--
-- Founder-created workspaces are flagged rather than dropped, the same way
-- `founder_user_costs` treats internal traffic: our own test workspace is worth
-- seeing and worth excluding from a number about customers, and only a flag
-- lets the page do both.

create or replace function public.founder_workspaces()
returns table (
  org_id uuid,
  name text,
  created_at timestamptz,
  deleted_at timestamptz,
  creator_email text,
  creator_is_internal boolean,
  -- Members who hold a seat today. `org_members.status` also carries states
  -- that do not, so the two are reported apart rather than summed.
  members_active bigint,
  members_other bigint,
  -- An invite is pending only while it can still be accepted: not accepted,
  -- not revoked, not past its expiry.
  invites_sent bigint,
  invites_accepted bigint,
  invites_pending bigint,
  invites_dead bigint,
  teams bigint,
  plan text,
  sub_status text,
  seats integer,
  converted_at timestamptz,
  -- Work actually done inside the workspace: content stamped to it, and the
  -- proxy calls its pool paid for.
  meetings bigint,
  action_items bigint,
  transcription_hours numeric,
  cost_usd numeric,
  last_activity_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public._assert_founder();
  return query
  select
    o.id,
    o.name,
    o.created_at,
    o.deleted_at,
    u.email::text,
    lower(u.email) = any(public._founder_emails()),
    coalesce(m.active, 0),
    coalesce(m.other, 0),
    coalesce(i.sent, 0),
    coalesce(i.accepted, 0),
    coalesce(i.pending, 0),
    coalesce(i.dead, 0),
    coalesce(t.n, 0),
    s.plan,
    s.status,
    s.seats,
    s.converted_at,
    coalesce(mt.n, 0),
    coalesce(ai.n, 0),
    coalesce(ue.hours, 0),
    coalesce(ue.cost, 0),
    greatest(mt.last_at, ue.last_at)
  from public.organizations o
  join auth.users u on u.id = o.created_by
  left join lateral (
    select
      count(*) filter (where om.status = 'active') as active,
      count(*) filter (where om.status is distinct from 'active') as other
    from public.org_members om where om.org_id = o.id
  ) m on true
  left join lateral (
    select
      count(*) as sent,
      count(*) filter (where oi.accepted_at is not null) as accepted,
      count(*) filter (
        where oi.accepted_at is null
          and oi.revoked_at is null
          and (oi.expires_at is null or oi.expires_at > now())
      ) as pending,
      count(*) filter (
        where oi.accepted_at is null
          and (oi.revoked_at is not null
               or (oi.expires_at is not null and oi.expires_at <= now()))
      ) as dead
    from public.org_invites oi where oi.org_id = o.id
  ) i on true
  left join lateral (
    select count(*) as n from public.teams tm
    where tm.org_id = o.id and tm.deleted_at is null
  ) t on true
  left join public.org_subscriptions s on s.org_id = o.id
  left join lateral (
    select count(*) as n, max(mm.created_at) as last_at
    from public.meetings mm where mm.org_id = o.id
  ) mt on true
  left join lateral (
    select count(*) as n from public.action_items a where a.org_id = o.id
  ) ai on true
  left join lateral (
    select
      round(coalesce(sum(e.audio_seconds), 0) / 3600.0, 2) as hours,
      round(coalesce(sum(e.cost_usd), 0), 6) as cost,
      max(e.created_at) as last_at
    from public.usage_events e where e.org_id = o.id
  ) ue on true
  order by o.created_at desc;
end;
$$;

revoke all on function public.founder_workspaces() from public, anon;
grant execute on function public.founder_workspaces() to authenticated;

comment on function public.founder_workspaces() is
  'One row per workspace: who made it, who joined, which invites are still live, what it produced and whether it pays. Founder-gated.';
