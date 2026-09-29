-- Retrieval must not read sessions the user deleted — the third place that
-- forgot.
--
-- `20260802122748` fixed it for transcript chunks and `ActionItemStore.openItems`
-- for tasks; both name the same cause. `concepts.meeting_id` references
-- `meetings` `on delete cascade`, trashing is a soft delete (`deleted_at`), so
-- the cascade never fires and a distilled fact outlives the session it came
-- from. `match_concepts` shipped a month after that fix and never carried the
-- filter.
--
-- What the user saw: `KnowledgeChatStore.establishedFactsBlock` labels a fact
-- with its session, resolved through the client's meetings map — which is
-- `deleted_at is null`. A fact from a trashed session resolves to nothing and
-- has no provider either, so the line reaches the model with no origin at all:
-- a decision or a commitment presented as established, with nothing to click
-- and nothing to check. Sandbox at the time of writing: 20 current concepts
-- from 25 trashed sessions; prod: 0, so this closes the hole before it opens
-- there.
--
-- `left join`, not `join`: an integration-sourced fact carries `provider` and
-- `external_key` with a null `meeting_id`, and an inner join would drop every
-- one of them.
--
-- Filtered at query time rather than deleted on trash, for the reason
-- `20260802122748` gives: restoring from trash has to bring the session back
-- whole, and this way its facts come back with it at no cost.
--
-- Deploy order and rollback. Additive and one-sided — no client change, no
-- payload change, the function only returns fewer rows. Apply before or after
-- any client ships; roll back by restoring the previous body. No retirement
-- gate and no legacy path to remove.
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
    left join public.meetings m on m.id = c.meeting_id
    where c.user_id = p_user_id
      and c.state = 'current'
      and (c.meeting_id is null or m.deleted_at is null)
      and (p_entity_ids is null or c.entity_id = any (p_entity_ids))
    order by
        (c.embedding is null),
        c.embedding OPERATOR(public.<=>) query_embedding
    limit match_count;
$$;

revoke all on function public.match_concepts(vector(384), int, uuid, uuid[]) from public, anon;
grant execute on function public.match_concepts(vector(384), int, uuid, uuid[]) to authenticated, service_role;
