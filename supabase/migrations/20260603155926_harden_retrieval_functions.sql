-- Entity boost over-matched. `p_query ilike '%' || normalized_name || '%'`
-- treated % and _ in an LLM-extracted entity name as LIKE wildcards: a topic
-- normalizing to 'q4_planning' matched 'q4xplanning', and a name containing '%'
-- matched almost any query — lifting unrelated sessions to the top of
-- cross-session search. Use a literal substring test instead. normalized_name
-- is already lower/trimmed, so compare it against lower(p_query); the
-- char_length guard still skips 1-2 char names that would match everything.
create or replace function public.meetings_matching_entities(
    p_user_id uuid,
    p_query text
)
returns table (meeting_id uuid)
language sql
stable
as $$
    select distinct me.meeting_id
    from public.entities e
    join public.meeting_entities me on me.entity_id = e.id
    where e.user_id = p_user_id
      and char_length(e.normalized_name) >= 3
      and position(e.normalized_name in lower(p_query)) > 0;
$$;

grant execute on function public.meetings_matching_entities(uuid, text)
    to authenticated, service_role;

-- Trust-boundary note for match_session_chunks (unchanged here): it is granted
-- to service_role and called that way by the llm-proxy, where RLS is bypassed.
-- Row scoping on that path is the `e.user_id = p_user_id` predicate (p_user_id
-- = the JWT-verified user), NOT RLS. RLS only backstops direct `authenticated`
-- callers. Earlier comments claiming RLS "independently scopes" the service
-- role path were misleading; do not weaken the predicate.
