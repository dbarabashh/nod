-- The observation ledger: what the user keeps doing, in one countable shape.
--
-- The evidence of repetition already exists — proposals approved, items moved,
-- beats answered — but in four tables with four shapes, and nothing counts it.
-- This adds the one genuinely new stream (tool approvals, which today
-- evaporate the moment the card is answered), a view that reads the existing
-- rows into one ledger, and the miner that turns the ledger into pattern
-- candidates. Everything here ships dark: no client renders any of it yet.
--
-- The ledger is DERIVED, never collected. Every row of the view is
-- reconstructible from a row the user can already see and delete, and deleting
-- the source deletes the observation with it. The moment something appears
-- here that nothing else writes, `privacy.md` § 3.8 stops being true — that is
-- the line, and `tool_approvals` sits inside it because the card the user
-- answered is theirs to see too.

create table public.tool_approvals (
    id         uuid        primary key default gen_random_uuid(),
    user_id    uuid        not null references auth.users(id) on delete cascade,
    provider   text        not null,
    -- Action names on the card, never their parameters: "linear.create_issue",
    -- not what was in it.
    actions    text[]      not null check (array_length(actions, 1) between 1 and 8),
    mutating   boolean     not null,
    allowed    boolean     not null,
    -- Reads that ran unasked because the person set "allow reads" — kept apart
    -- from decisions actually made at a card, or the miner would count a
    -- preference as a hundred enthusiastic approvals.
    unasked    boolean     not null default false,
    created_at timestamptz not null default now()
);

create index tool_approvals_user_idx on public.tool_approvals (user_id, created_at desc);

alter table public.tool_approvals enable row level security;

create policy "users read own tool approvals"
    on public.tool_approvals for select to authenticated
    using (auth.uid() = user_id);

create policy "users insert own tool approvals"
    on public.tool_approvals for insert to authenticated
    with check (auth.uid() = user_id);

create policy "users delete own tool approvals"
    on public.tool_approvals for delete to authenticated
    using (auth.uid() = user_id);

-- One ledger over the rows that already exist. `security_invoker` so every
-- select runs under the caller's own RLS — the view adds a shape, never a
-- door. `context_key` is the whole trick: it is what makes ten approvals one
-- habit instead of ten events.
create view public.observations
with (security_invoker = true)
as
select
    p.id,
    p.user_id,
    'proposal_' || p.status as kind,
    p.type                  as subject,
    p.type                  as context_key,
    p.created_at            as at
from public.action_proposals p
where p.status in ('approved', 'completed', 'rejected')
union all
select
    t.id,
    t.user_id,
    'tool_' || case when t.allowed then 'allowed' else 'denied' end,
    t.provider,
    t.provider || ':' || array_to_string(t.actions, '+')
        || case when t.mutating then ':write' else ':read' end,
    t.created_at
from public.tool_approvals t
where not t.unasked
union all
select
    tr.id,
    tr.user_id,
    'item_' || tr.to_state,
    coalesce(tr.reason, ''),
    'item:' || tr.actor,
    tr.at
from public.action_item_transitions tr
union all
select
    br.id,
    br.user_id,
    'beat_' || br.status,
    b.title,
    'beat:' || br.beat_id::text,
    coalesce(br.finished_at, br.scheduled_for)
from public.beat_runs br
join public.beats b on b.id = br.beat_id;

grant select on public.observations to authenticated, service_role;

create table public.pattern_candidates (
    id          uuid        primary key default gen_random_uuid(),
    user_id     uuid        not null references auth.users(id) on delete cascade,
    context_key text        not null,
    support     integer     not null,
    rejected    integer     not null default 0,
    first_at    timestamptz not null,
    last_at     timestamptz not null,
    -- `candidate` until a recap shows it; the person's answer is the whole
    -- point of the row existing.
    status      text        not null default 'candidate'
                check (status in ('candidate', 'offered', 'accepted', 'dismissed')),
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    -- One live candidate per habit: a re-mine refreshes the row rather than
    -- stacking a second copy of the same suggestion.
    unique (user_id, context_key)
);

create index pattern_candidates_user_idx on public.pattern_candidates (user_id, status);

alter table public.pattern_candidates enable row level security;

create policy "users read own pattern candidates"
    on public.pattern_candidates for select to authenticated
    using (auth.uid() = user_id);

-- The person may answer a card (offered → accepted/dismissed); only the miner
-- may create or re-support one.
create policy "users answer own pattern candidates"
    on public.pattern_candidates for update to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

-- The miner. Arithmetic decides that something is a pattern; a model only ever
-- writes the sentence a person reads. The thresholds are the product defence
-- against twenty half-useful suggestions: at least 3 approvals of the same
-- shape, at most one rejection in five, observed across at least three weeks.
-- They are parameters so the calibration pass can measure real distributions
-- before a single card ships.
create or replace function public.mine_pattern_candidates(
    p_user_id uuid,
    p_min_support integer default 3,
    p_min_precision numeric default 0.8,
    p_min_span interval default '21 days',
    p_window interval default '90 days'
)
returns setof public.pattern_candidates
language plpgsql
security definer
set search_path = ''
as $$
begin
    return query
    with decided as (
        select
            p.type,
            count(*) filter (where p.status in ('approved', 'completed')) as approvals,
            count(*) filter (where p.status = 'rejected')                 as rejections,
            min(p.created_at)                                            as first_at,
            max(p.created_at)                                            as last_at
        from public.action_proposals p
        where p.user_id = p_user_id
          and p.created_at > now() - p_window
          and p.status in ('approved', 'completed', 'rejected')
        group by p.type
    ),
    qualifying as (
        select * from decided
        where approvals >= p_min_support
          and last_at - first_at >= p_min_span
          and approvals::numeric / (approvals + rejections) >= p_min_precision
    )
    insert into public.pattern_candidates as pc
        (user_id, context_key, support, rejected, first_at, last_at)
    select p_user_id, q.type, q.approvals, q.rejections, q.first_at, q.last_at
      from qualifying q
    on conflict (user_id, context_key) do update
       set support = excluded.support,
           rejected = excluded.rejected,
           last_at = excluded.last_at,
           updated_at = now()
        -- A candidate the person already answered stays answered. Re-offering
        -- a dismissed habit every week is how the card gets ignored forever.
        where pc.status in ('candidate', 'offered')
    returning pc.*;
end;
$$;

revoke all on function public.mine_pattern_candidates(uuid, integer, numeric, interval, interval) from public, anon, authenticated;
grant execute on function public.mine_pattern_candidates(uuid, integer, numeric, interval, interval) to service_role;
