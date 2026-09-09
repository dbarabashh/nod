-- A session shared with me answers my questions too.
--
-- `session_embeddings` already lets a teammate read the chunks of a session
-- shared with them, directly or through a folder ("members read embeddings
-- shared directly", "… shared through a folder"), and the session sits in
-- their list beside their own, with its commitments on Today. But
-- `match_session_chunks` — which runs as the service role for the proxy, so
-- no policy is consulted — kept `e.user_id = p_user_id`, and a question about
-- a teammate's session, even one pinned by name, came back with nothing:
-- "I don't have that session in the excerpts".
--
-- Expand only: the same signature returns the rows it did plus the ones the
-- two policies already allow. Both read `auth.uid()`, which the service role
-- does not carry, so the same two predicates are spelled once more over an
-- explicit user.

create or replace function public._meetings_shared_with(p_user_id uuid)
    returns setof uuid
    language sql
    stable
    security definer
    set search_path = ''
as $$
    select ms.meeting_id
      from public.meeting_grants ms
     where (ms.team_id is not null
            and public._team_membership_grants_content(ms.team_id, p_user_id))
        or (ms.org_id is not null and exists (
               select 1 from public.org_members om
                where om.org_id = ms.org_id and om.user_id = p_user_id and om.status = 'active'
           ))
    union
    select ml.meeting_id
      from public.meeting_labels ml
      join public.folder_shares fs on fs.label_id = ml.label_id
     where (fs.team_id is not null
            and public._team_membership_grants_content(fs.team_id, p_user_id))
        or (fs.org_id is not null and exists (
               select 1 from public.org_members om
                where om.org_id = fs.org_id and om.user_id = p_user_id and om.status = 'active'
           ));
$$;

revoke all on function public._meetings_shared_with(uuid) from public, anon;
grant execute on function public._meetings_shared_with(uuid) to service_role;

-- The helper takes any user id, so `authenticated` must not reach it, and
-- a function `authenticated` cannot finish is not one to keep granting: every
-- caller of `match_session_chunks` is the proxy or a worker, as the service
-- role. The grant from `20260802122748` was never used by a client, and the
-- `public` grant Postgres hands every new function had survived beneath it,
-- with `anon` inheriting it.
revoke all on function public.match_session_chunks(vector(384), int, uuid, uuid, uuid[])
    from public, anon, authenticated;
grant execute on function public.match_session_chunks(vector(384), int, uuid, uuid, uuid[]) to service_role;

create or replace function public.match_session_chunks(
    query_embedding vector(384),
    match_count int,
    p_user_id uuid,
    p_meeting_id uuid default null,
    p_meeting_ids uuid[] default null
)
returns table (meeting_id uuid, content text, similarity float)
language sql
stable
set search_path = ''
as $$
    select c.meeting_id, c.content, c.similarity
    from (
        select
            e.meeting_id,
            e.content,
            1 - (e.embedding OPERATOR(public.<=>) query_embedding) as similarity,
            coalesce(e.started_at, e.created_at) as occurred_at
        from public.session_embeddings e
        join public.meetings m on m.id = e.meeting_id
        where (e.user_id = p_user_id
               or e.meeting_id in (select public._meetings_shared_with(p_user_id)))
          and m.deleted_at is null
          and (p_meeting_id  is null or e.meeting_id =     p_meeting_id)
          and (p_meeting_ids is null or e.meeting_id = any(p_meeting_ids))
        order by e.embedding OPERATOR(public.<=>) query_embedding
        limit greatest(match_count * 4, 40)
    ) c
    order by c.similarity
        + 0.06 * exp(-extract(epoch from (now() - c.occurred_at)) / 2592000.0) desc
    limit match_count;
$$;
