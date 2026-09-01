-- Agents: a declared record, never generated code.
--
-- v1 carries one trigger, `after_meeting` — the Mac that just recorded a
-- session is awake by definition, so the run needs no claim race and no cron.
-- Time-triggered agents already exist and are called beats; they stay beats
-- until there is a second real reason to generalise the runner.
--
-- The trust ladder is in the schema now so a released client can already read
-- it, but the v1 runtime only ever executes `l1`: trigger, read, write a
-- thread. What keeps that safe is not this table — it is the unattended chat's
-- tool catalogue, which holds no mutating tool at all. `agent_grants` lands
-- here dark for the same reason the trust column does: the wire shape is the
-- contract, and expanding it later in place is what backward-compatibility
-- forbids.

create table public.agents (
    id              uuid        primary key default gen_random_uuid(),
    user_id         uuid        not null references auth.users(id) on delete cascade,
    title           text        not null check (length(btrim(title)) between 1 and 120),
    -- Whatever a person could type into Ask Nod, exactly as beats hold it.
    prompt          text        not null check (length(btrim(prompt)) between 1 and 2000),
    trigger_kind    text        not null default 'after_meeting'
                    check (trigger_kind in ('after_meeting')),
    -- `on_change` is the default for anything born from a pattern: an agent
    -- that speaks after every session gets muted, and then the one message
    -- that mattered is muted with it. `always` exists for the person who
    -- explicitly asks for a briefing every time.
    speaks          text        not null default 'on_change'
                    check (speaks in ('always', 'on_change')),
    trust           text        not null default 'l1'
                    check (trust in ('l0', 'l1', 'l2', 'l3')),
    status          text        not null default 'active'
                    check (status in ('active', 'paused', 'dormant', 'archived')),
    -- The habit that proposed it, when a pattern did. An agent the user typed
    -- up from nothing carries null here, honestly.
    origin_pattern  uuid        references public.pattern_candidates(id) on delete set null,
    -- A client that does not know a version refuses to run the agent — a
    -- half-understood agent still acts, which is worse than one that waits.
    spec_version    integer     not null default 1,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);

create index agents_user_idx on public.agents (user_id, status);

create table public.agent_runs (
    id           uuid        primary key default gen_random_uuid(),
    agent_id     uuid        not null references public.agents(id) on delete cascade,
    user_id      uuid        not null references auth.users(id) on delete cascade,
    meeting_id   uuid        references public.meetings(id) on delete set null,
    status       text        not null default 'started'
                 check (status in ('started', 'done', 'gate_skipped', 'failed')),
    -- The thread the answer was written into, exactly as a beat run keeps its.
    thread_id    uuid        references public.knowledge_threads(id) on delete set null,
    error        text,
    started_at   timestamptz not null default now(),
    finished_at  timestamptz
);

-- One run per agent per meeting: a re-enrichment (summary regenerated, late
-- speakers) must not run the same agent over the same session twice.
create unique index agent_runs_once_per_meeting
    on public.agent_runs (agent_id, meeting_id) where meeting_id is not null;
create index agent_runs_user_idx on public.agent_runs (user_id, started_at desc);

-- Standing permission, dark in v1: no runtime reads it yet, but the shape —
-- one provider, one action, a rate, an expiry, a named granter — is the
-- contract every later client speaks. A grant is a row so revocation and
-- expiry are queries, and recertification is "the row expired".
create table public.agent_grants (
    id           uuid        primary key default gen_random_uuid(),
    agent_id     uuid        not null references public.agents(id) on delete cascade,
    user_id      uuid        not null references auth.users(id) on delete cascade,
    provider     text        not null,
    action       text        not null,
    per_week     integer     not null default 5 check (per_week between 1 and 50),
    expires_at   timestamptz not null,
    granted_by   uuid        not null references auth.users(id) on delete cascade,
    revoked_at   timestamptz,
    created_at   timestamptz not null default now()
);

create index agent_grants_agent_idx on public.agent_grants (agent_id) where revoked_at is null;

alter table public.agents enable row level security;
alter table public.agent_runs enable row level security;
alter table public.agent_grants enable row level security;

create policy "users read own agents"
    on public.agents for select to authenticated
    using (auth.uid() = user_id);
create policy "users insert own agents"
    on public.agents for insert to authenticated
    with check (auth.uid() = user_id);
create policy "users update own agents"
    on public.agents for update to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);
create policy "users delete own agents"
    on public.agents for delete to authenticated
    using (auth.uid() = user_id);

create policy "users read own agent runs"
    on public.agent_runs for select to authenticated
    using (auth.uid() = user_id);
-- The after-meeting runner is the owner's own Mac, so unlike a beat run —
-- which exists because a schedule came due — an agent run is the client's to
-- open and to finish.
create policy "users insert own agent runs"
    on public.agent_runs for insert to authenticated
    with check (auth.uid() = user_id);
create policy "users update own agent runs"
    on public.agent_runs for update to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

create policy "users read own agent grants"
    on public.agent_grants for select to authenticated
    using (auth.uid() = user_id);
-- Granting is deliberately NOT open to plain inserts: v1 ships no surface that
-- may create standing permission, and a closed table cannot be talked into
-- one. The grant RPC arrives with the runtime that enforces it.

-- The person's own miner. The service-role variant exists for sweeps; this one
-- is what lets the client refresh candidates after a meeting without holding a
-- key that could mine anyone.
create or replace function public.mine_my_patterns()
returns setof public.pattern_candidates
language plpgsql
security definer
set search_path = ''
as $$
begin
    if auth.uid() is null then
        raise exception 'authentication required';
    end if;
    return query select * from public.mine_pattern_candidates(auth.uid());
end;
$$;

-- The two answers a card can produce. Updates guarded by current status so a
-- stale card cannot resurrect a dismissed habit.
create or replace function public.answer_pattern_candidate(
    p_candidate uuid,
    p_accept boolean
)
returns setof public.pattern_candidates
language plpgsql
security definer
set search_path = ''
as $$
begin
    if auth.uid() is null then
        raise exception 'authentication required';
    end if;
    return query
        update public.pattern_candidates
           set status = case when p_accept then 'accepted' else 'dismissed' end,
               updated_at = now()
         where id = p_candidate
           and user_id = auth.uid()
           and status in ('candidate', 'offered')
        returning *;
end;
$$;

revoke all on function public.mine_my_patterns() from public, anon;
revoke all on function public.answer_pattern_candidate(uuid, boolean) from public, anon;
grant execute on function public.mine_my_patterns() to authenticated;
grant execute on function public.answer_pattern_candidate(uuid, boolean) to authenticated;
