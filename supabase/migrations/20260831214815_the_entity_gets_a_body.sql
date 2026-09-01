-- Concepts: the body of a node in the entity graph.
--
-- `entities` knows that "Atlas" exists and which sessions mentioned it, and
-- nothing else — every question about Atlas re-reads raw transcript chunks and
-- reassembles the answer from speech. A concept is one distilled statement
-- hung on an entity, with the evidence that taught it and the window of time
-- it was true.
--
-- Two clocks, deliberately. A meeting recorded today can contain a fact about
-- last month, and one timestamp cannot tell "we learned late about an old
-- thing" from "a new decision was made". `valid_from`/`valid_to` is when the
-- fact held in the world; `recorded_at` is when a session taught us.
--
-- Facts are corrected, not stacked: a contradicted concept is marked
-- superseded and points at what replaced it. Nothing is deleted — asked next
-- March what we believed in October, the record answers.

create extension if not exists btree_gist with schema extensions;

create table public.concepts (
    id            uuid        primary key default gen_random_uuid(),
    user_id       uuid        not null references auth.users(id) on delete cascade,
    entity_id     uuid        not null references public.entities(id) on delete cascade,
    -- Decisions and commitments are exempt from any future pruning: they are
    -- exactly what recall exists to bring back.
    kind          text        not null check (kind in ('fact', 'decision', 'commitment', 'preference')),
    -- Which claim about the entity this is ("ship-date", "pricing"), assigned
    -- by the distiller. It is what lets the engine hold "one current version
    -- of a claim" as a constraint rather than a hope.
    claim_key     text        not null check (length(btrim(claim_key)) between 1 and 80),
    body          text        not null check (length(btrim(body)) between 1 and 500),
    -- A meeting-sourced fact is history: what was said was said. An
    -- integration-sourced fact is a cached view of a system of record that can
    -- change without telling us — it is re-checked, never trusted.
    source        text        not null check (source in ('meeting', 'integration', 'chat')),
    meeting_id    uuid        references public.meetings(id) on delete cascade,
    -- The transcript line that taught it (`meeting_transcripts.idx`) — the
    -- same anchor `action_items.evidence_idx` carries, and just as
    -- unrecoverable later.
    evidence_idx  integer,
    provider      text,
    external_key  text,
    valid_from    timestamptz not null default now(),
    valid_to      timestamptz,
    recorded_at   timestamptz not null default now(),
    state         text        not null default 'current'
                  check (state in ('current', 'superseded', 'archived')),
    superseded_by uuid        references public.concepts(id) on delete set null,
    confidence    numeric(3, 2) check (confidence is null or confidence between 0 and 1),
    -- gte-small, embedded server-side like every transcript chunk. Nullable:
    -- a concept written by a client action (the recall card's "this replaces
    -- it") arrives without one and is still reachable through its entity.
    embedding     vector(384),
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    -- A superseded concept says by what; nothing else may claim to be.
    check ((state = 'superseded') = (superseded_by is not null)),
    -- Leaving `current` closes the validity window.
    check (state = 'current' or valid_to is not null)
);

-- The invariant the whole layer rests on, held by the engine: one current
-- version of a claim per entity. Current rows run to infinity, so any second
-- current row for the same claim overlaps and is refused.
-- Deferred so `supersede_concept` and `apply_concept` can write the
-- replacement before closing the old row inside one transaction; at commit,
-- exactly one current version stands.
alter table public.concepts
    add constraint concepts_one_current_claim
    exclude using gist (
        entity_id with =,
        claim_key with =,
        tstzrange(valid_from, coalesce(valid_to, 'infinity')) with &&
    ) where (state = 'current')
    deferrable initially deferred;

create index concepts_entity_idx  on public.concepts (entity_id, state);
create index concepts_user_idx    on public.concepts (user_id, updated_at desc);
create index concepts_meeting_idx on public.concepts (meeting_id) where meeting_id is not null;
create index concepts_vec_idx     on public.concepts using hnsw (embedding vector_cosine_ops);

alter table public.concepts enable row level security;

create policy "users read own concepts"
    on public.concepts for select to authenticated
    using (auth.uid() = user_id);

-- Insert/update stay closed to clients: concepts are written by the distiller
-- (service role) and by the two RPCs below, which carry their own checks. A
-- client that could write rows directly could also write a `current` row that
-- contradicts the exclusion story.
create policy "users delete own concepts"
    on public.concepts for delete to authenticated
    using (auth.uid() = user_id);

-- Entities named in a query, for the concept-first retrieval stage. Same
-- length guard as `meetings_matching_entities`: 1–2 char names match noise.
create or replace function public.entities_matching_query(
    p_user_id uuid,
    p_query text
)
returns table (entity_id uuid)
language sql
stable
set search_path = ''
as $$
    select e.id
      from public.entities e
     where e.user_id = p_user_id
       and char_length(e.normalized_name) >= 3
       and position(e.normalized_name in lower(p_query)) > 0;
$$;

-- Stage one of retrieval: current concepts, scoped to the entities the
-- question names when it names any. Rows without an embedding rank after
-- embedded ones instead of vanishing — a fact written seconds ago by the
-- recall card must be findable before anything re-embeds it.
create or replace function public.match_concepts(
    query_embedding vector(384),
    match_count int,
    p_user_id uuid,
    p_entity_ids uuid[] default null
)
returns table (
    id uuid,
    entity_id uuid,
    kind text,
    claim_key text,
    body text,
    valid_from timestamptz,
    meeting_id uuid,
    provider text,
    external_key text,
    similarity float
)
language sql
stable
set search_path = ''
as $$
    select
        c.id,
        c.entity_id,
        c.kind,
        c.claim_key,
        c.body,
        c.valid_from,
        c.meeting_id,
        c.provider,
        c.external_key,
        case when c.embedding is null then 0.0
             else 1 - (c.embedding OPERATOR(public.<=>) query_embedding) end as similarity
    from public.concepts c
    where c.user_id = p_user_id
      and c.state = 'current'
      and (p_entity_ids is null or c.entity_id = any (p_entity_ids))
    order by
        (c.embedding is null),
        c.embedding OPERATOR(public.<=>) query_embedding
    limit match_count;
$$;

-- What replaced a fact, for answers that say "changed 21 Sep": the current
-- concept plus the chain it superseded, newest first.
create or replace function public.concept_history(p_concept uuid)
returns setof public.concepts
language sql
stable
security definer
set search_path = ''
as $$
    with recursive chain as (
        select c.* from public.concepts c
         where c.id = p_concept and c.user_id = auth.uid()
        union all
        select prev.* from public.concepts prev
          join chain on prev.superseded_by = chain.id
    )
    select * from chain order by valid_from desc;
$$;

-- The recall card's "this replaces it": one tap marks the old concept
-- superseded and writes what the room just said as the current version of the
-- same claim. One transaction, so there is no instant where the claim has no
-- current answer and no instant where it has two.
create or replace function public.supersede_concept(
    p_concept uuid,
    p_body text,
    p_meeting uuid default null,
    p_evidence_idx integer default null
)
returns setof public.concepts
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_old public.concepts;
    v_new public.concepts;
begin
    if auth.uid() is null then
        raise exception 'authentication required';
    end if;
    if p_body is null or length(btrim(p_body)) = 0 then
        raise exception 'replacement body required';
    end if;

    select * into v_old
      from public.concepts
     where id = p_concept and user_id = auth.uid() and state = 'current'
       for update;
    if not found then
        return;
    end if;

    insert into public.concepts (
        user_id, entity_id, kind, claim_key, body, source,
        meeting_id, evidence_idx, valid_from, recorded_at
    ) values (
        v_old.user_id, v_old.entity_id, v_old.kind, v_old.claim_key,
        btrim(p_body), case when p_meeting is null then 'chat' else 'meeting' end,
        p_meeting, p_evidence_idx, now(), now()
    )
    returning * into v_new;

    update public.concepts
       set state = 'superseded',
           superseded_by = v_new.id,
           valid_to = now(),
           updated_at = now()
     where id = v_old.id;

    return next v_new;
end;
$$;

-- The distiller's one primitive, ADD and UPDATE in a single shape: insert the
-- claim's new current version, superseding the old one if it exists. Runs as
-- one transaction — the two REST calls a service-role client would otherwise
-- make cannot satisfy the exclusion and the superseded checks in either order.
-- `p_decision` comes back so the caller can count adds against updates without
-- a second read.
create or replace function public.apply_concept(
    p_user_id uuid,
    p_entity_id uuid,
    p_kind text,
    p_claim_key text,
    p_body text,
    p_source text,
    p_meeting uuid default null,
    p_evidence_idx integer default null,
    p_provider text default null,
    p_external_key text default null,
    p_confidence numeric default null,
    p_embedding vector(384) default null,
    p_valid_from timestamptz default null
)
returns table (concept_id uuid, decision text)
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_old public.concepts;
    v_had_old boolean;
    v_new_id uuid;
    v_from timestamptz;
begin
    select * into v_old
      from public.concepts
     where user_id = p_user_id
       and entity_id = p_entity_id
       and claim_key = p_claim_key
       and state = 'current'
       for update;
    v_had_old := found;
    -- A late-learned fact may claim an old start, but never one before the row
    -- it supersedes: that would make the old row's window run backwards.
    v_from := coalesce(p_valid_from, now());
    if v_had_old then
        v_from := greatest(v_from, v_old.valid_from);
    end if;

    -- The same words again is a no-op, not a churned row: retrieval would see
    -- an identical body with a newer date and learn nothing from it.
    if v_had_old and btrim(v_old.body) = btrim(p_body) then
        return query select v_old.id, 'noop'::text;
        return;
    end if;

    insert into public.concepts (
        user_id, entity_id, kind, claim_key, body, source,
        meeting_id, evidence_idx, provider, external_key,
        confidence, embedding, valid_from, recorded_at
    ) values (
        p_user_id, p_entity_id, p_kind, p_claim_key, btrim(p_body), p_source,
        p_meeting, p_evidence_idx, p_provider, p_external_key,
        p_confidence, p_embedding, v_from, now()
    )
    returning id into v_new_id;

    if v_had_old then
        update public.concepts
           set state = 'superseded',
               superseded_by = v_new_id,
               valid_to = v_from,
               updated_at = now()
         where id = v_old.id;
        return query select v_new_id, 'updated'::text;
    else
        return query select v_new_id, 'added'::text;
    end if;
end;
$$;

-- Postgres hands EXECUTE to PUBLIC on every new function and `anon` inherits
-- it — revoke first, then grant exactly who may call.
revoke all on function public.entities_matching_query(uuid, text) from public, anon;
revoke all on function public.match_concepts(vector(384), int, uuid, uuid[]) from public, anon;
revoke all on function public.concept_history(uuid) from public, anon;
revoke all on function public.supersede_concept(uuid, text, uuid, integer) from public, anon;
revoke all on function public.apply_concept(uuid, uuid, text, text, text, text, uuid, integer, text, text, numeric, vector(384), timestamptz) from public, anon, authenticated;

grant execute on function public.entities_matching_query(uuid, text) to authenticated, service_role;
grant execute on function public.match_concepts(vector(384), int, uuid, uuid[]) to authenticated, service_role;
grant execute on function public.concept_history(uuid) to authenticated;
grant execute on function public.supersede_concept(uuid, text, uuid, integer) to authenticated;
grant execute on function public.apply_concept(uuid, uuid, text, text, text, text, uuid, integer, text, text, numeric, vector(384), timestamptz) to service_role;
