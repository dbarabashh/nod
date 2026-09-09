-- Phase 6 (minimal context graph), Phase 7 (minimal evidence gathering,
-- deterministic — no vector retrieval needed for this slice, the prior
-- meeting's own chunks already exist from Phase 3) and Phase 8 (briefings
-- schema) for the plan's own "Recommended First Vertical Slice" (§16):
-- upcoming calendar event -> prior meeting resolution -> evidence pack ->
-- briefing. LLM generation itself lives in `calendar-sync` (TypeScript,
-- Phase 8 follow-up migration) since only Deno can call the completion API;
-- everything here is deterministic SQL.
--
-- The prior-meeting matcher fixes a real bug found while building this:
-- `Nod/Nod/Features/Home/TodayBrief.swift`'s existing `lastSession(before:in:)`
-- (still live, still what today's plain "Last time: N actions" line uses)
-- matches on a SINGLE shared first-name token with no length floor beyond 3
-- characters and no recency/exclusivity guard — two unrelated meetings that
-- happen to share an "Alex" or "Max" attendee are indistinguishable to it.
-- That is a plausible root cause for a synthesis feature landing on the wrong
-- meeting entirely. This matcher requires >= 2 overlapping tokens for its
-- attendee-overlap tier and prefers exact calendar identity first.

-- ── context_nodes / context_edges (§6.4) ────────────────────────────────────

create table public.context_nodes (
    id                uuid        primary key default gen_random_uuid(),
    user_id           uuid        not null references auth.users(id) on delete cascade,
    org_id            uuid        references public.organizations(id),
    node_type         text        not null,
    source_object_id  uuid        references public.source_objects(id) on delete cascade,
    native_table      text,
    native_id         uuid,
    canonical_key     text,
    title             text,
    occurred_at       timestamptz,
    state             jsonb       not null default '{}',
    created_at        timestamptz not null default now(),
    updated_at        timestamptz not null default now(),
    unique (source_object_id)
);

create index context_nodes_user_idx on public.context_nodes (user_id);
create index context_nodes_native_idx on public.context_nodes (native_table, native_id) where native_table is not null;

alter table public.context_nodes enable row level security;

create policy "owners read own context nodes"
    on public.context_nodes for select to authenticated
    using ((select auth.uid()) = user_id);

grant select, insert, update on table public.context_nodes to service_role;

create trigger stamp_org_id before insert or update of org_id on public.context_nodes
    for each row execute function public._stamp_org_id_from_context();

create table public.context_edges (
    id               uuid        primary key default gen_random_uuid(),
    user_id          uuid        not null references auth.users(id) on delete cascade,
    org_id           uuid        references public.organizations(id),
    from_node_id     uuid        not null references public.context_nodes(id) on delete cascade,
    to_node_id       uuid        not null references public.context_nodes(id) on delete cascade,
    relation         text        not null,
    confidence       numeric     not null check (confidence >= 0 and confidence <= 1),
    resolver         text        not null,
    evidence_ref_id  uuid,
    valid_from       timestamptz,
    valid_to         timestamptz,
    created_at       timestamptz not null default now()
);

-- The dedup key from §6.4: one active (valid_to is null) edge per
-- (nodes, relation, resolver).
create unique index context_edges_active_dedup_idx
    on public.context_edges (from_node_id, to_node_id, relation, resolver)
    where valid_to is null;
create index context_edges_from_idx on public.context_edges (from_node_id);
create index context_edges_to_idx on public.context_edges (to_node_id);

alter table public.context_edges enable row level security;

create policy "owners read own context edges"
    on public.context_edges for select to authenticated
    using ((select auth.uid()) = user_id);

grant select, insert on table public.context_edges to service_role;

create trigger stamp_org_id before insert or update of org_id on public.context_edges
    for each row execute function public._stamp_org_id_from_context();

-- ── evidence_refs (§6.5) ─────────────────────────────────────────────────────

create table public.evidence_refs (
    id                uuid        primary key default gen_random_uuid(),
    user_id           uuid        not null references auth.users(id) on delete cascade,
    org_id            uuid        references public.organizations(id),
    source_object_id  uuid        references public.source_objects(id) on delete cascade,
    source_chunk_id   uuid        references public.source_chunks(id) on delete cascade,
    native_table      text,
    native_id         uuid,
    locator           jsonb       not null default '{}',
    quote             text,
    observed_at       timestamptz,
    created_at        timestamptz not null default now()
);

create index evidence_refs_user_idx on public.evidence_refs (user_id);
create index evidence_refs_source_object_idx on public.evidence_refs (source_object_id) where source_object_id is not null;

alter table public.evidence_refs enable row level security;

create policy "owners read own evidence" on public.evidence_refs for select to authenticated
    using ((select auth.uid()) = user_id);

grant select, insert on table public.evidence_refs to service_role;

create trigger stamp_org_id before insert or update of org_id on public.evidence_refs
    for each row execute function public._stamp_org_id_from_context();

-- ── briefings / briefing_items / briefing_item_evidence (§6.6) ──────────────

create table public.briefings (
    id                uuid        primary key default gen_random_uuid(),
    user_id           uuid        not null references auth.users(id) on delete cascade,
    org_id            uuid        references public.organizations(id),
    briefing_type     text        not null check (briefing_type in ('onboarding_aha', 'upcoming_meeting', 'daily_focus')),
    target_node_id    uuid        references public.context_nodes(id) on delete cascade,
    status            text        not null default 'building'
        check (status in ('building', 'ready', 'stale', 'failed', 'dismissed')),
    headline          text,
    summary           text,
    confidence        numeric     check (confidence is null or (confidence >= 0 and confidence <= 1)),
    input_watermark   timestamptz not null,
    generator_version text        not null,
    generated_at      timestamptz,
    expires_at        timestamptz,
    failure_code      text
);

-- "unique active key" (§6.6): one row per (user, type, target) that is not
-- itself stale/dismissed/failed -- a fresh regeneration replaces it in place
-- (see `upsert_upcoming_meeting_briefing` below) rather than accumulating
-- history, which this slice has no reader for.
create unique index briefings_active_key_idx
    on public.briefings (user_id, briefing_type, target_node_id)
    where status in ('building', 'ready');

alter table public.briefings enable row level security;

create policy "owners read own briefings" on public.briefings for select to authenticated
    using ((select auth.uid()) = user_id);

grant select, insert, update, delete on table public.briefings to service_role;

create trigger stamp_org_id before insert or update of org_id on public.briefings
    for each row execute function public._stamp_org_id_from_context();

create table public.briefing_items (
    id               uuid        primary key default gen_random_uuid(),
    briefing_id      uuid        not null references public.briefings(id) on delete cascade,
    item_type        text        not null
        check (item_type in ('change', 'open_question', 'commitment', 'risk', 'document', 'suggested_action')),
    position         integer     not null,
    title            text        not null,
    body             text,
    target_node_id   uuid        references public.context_nodes(id) on delete set null,
    action_spec      jsonb,
    confidence       numeric     not null check (confidence >= 0 and confidence <= 1)
);

create index briefing_items_briefing_idx on public.briefing_items (briefing_id);

alter table public.briefing_items enable row level security;

create policy "owners read own briefing items" on public.briefing_items for select to authenticated
    using (
        exists (
            select 1 from public.briefings b
            where b.id = briefing_id and b.user_id = (select auth.uid())
        )
    );

grant select, insert, delete on table public.briefing_items to service_role;

create table public.briefing_item_evidence (
    briefing_item_id  uuid not null references public.briefing_items(id) on delete cascade,
    evidence_ref_id   uuid not null references public.evidence_refs(id) on delete cascade,
    primary key (briefing_item_id, evidence_ref_id)
);

alter table public.briefing_item_evidence enable row level security;

create policy "owners read own briefing item evidence" on public.briefing_item_evidence for select to authenticated
    using (
        exists (
            select 1 from public.briefing_items i
            join public.briefings b on b.id = i.briefing_id
            where i.id = briefing_item_id and b.user_id = (select auth.uid())
        )
    );

grant select, insert on table public.briefing_item_evidence to service_role;
