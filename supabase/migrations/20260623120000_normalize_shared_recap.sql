-- Normalize legacy recaps when serving a public share.
--
-- The public web viewer assumes the canonical recap shape `{"sections":[…]}`
-- and reads `recap_json.sections` directly. Meetings summarized before the
-- dynamic-section recap shipped still carry the legacy
-- `{topics,decisions,actions,open_questions}` shape (no `sections` key), so the
-- viewer dereferences `undefined` and crashes ("reading 'length' of
-- undefined") — a white screen for the recipient. The macOS app already
-- tolerates this via `MeetingRecap.legacySections`; this mirrors that mapping
-- on the server so the viewer always receives `sections`.

create or replace function public.normalize_recap_json(p jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
    select case
        when p is null then null
        when p ? 'sections' then p
        else jsonb_build_object('sections', (
            select coalesce(jsonb_agg(sec order by ord), '[]'::jsonb)
            from (
                select 1 as ord, jsonb_build_object(
                    'title', 'Topics covered',
                    'bullets', (
                        select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                            'text', coalesce(t->>'text', ''),
                            'quote', t->>'quote')))
                        from jsonb_array_elements(p->'topics') t
                    )
                ) as sec
                where jsonb_typeof(p->'topics') = 'array'
                  and jsonb_array_length(p->'topics') > 0

                union all
                select 2, jsonb_build_object(
                    'title', 'Decisions made',
                    'bullets', (
                        select jsonb_agg(jsonb_build_object(
                            'text', case
                                when nullif(d->>'why', '') is not null
                                    then concat_ws(' — ', nullif(d->>'text', ''), d->>'why')
                                else coalesce(d->>'text', '')
                            end))
                        from jsonb_array_elements(p->'decisions') d
                    )
                )
                where jsonb_typeof(p->'decisions') = 'array'
                  and jsonb_array_length(p->'decisions') > 0

                union all
                select 3, jsonb_build_object(
                    'title', 'Action items',
                    'bullets', (
                        select jsonb_agg(jsonb_build_object('text', (
                            with base as (
                                select case
                                    when nullif(a->>'owner', '') is not null
                                         and nullif(a->>'task', '') is not null
                                        then (a->>'owner') || ' — ' || (a->>'task')
                                    else coalesce(nullif(a->>'task', ''), nullif(a->>'owner', ''), '')
                                end as b
                            )
                            select case
                                when nullif(a->>'when', '') is not null
                                    then (select b from base) || ' (by ' || (a->>'when') || ')'
                                else (select b from base)
                            end
                        )))
                        from jsonb_array_elements(p->'actions') a
                    )
                )
                where jsonb_typeof(p->'actions') = 'array'
                  and jsonb_array_length(p->'actions') > 0

                union all
                select 4, jsonb_build_object(
                    'title', 'Open questions',
                    'bullets', (
                        select jsonb_agg(jsonb_build_object('text', coalesce(o->>'text', '')))
                        from jsonb_array_elements(p->'open_questions') o
                    )
                )
                where jsonb_typeof(p->'open_questions') = 'array'
                  and jsonb_array_length(p->'open_questions') > 0
            ) s
        ))
    end;
$$;

create or replace function public.get_shared_meeting(p_token uuid)
returns table (
    id          uuid,
    title       text,
    summary     text,
    recap_json  jsonb,
    kind        text,
    language    text,
    started_at  timestamptz,
    ended_at    timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
    select m.id, m.title, m.summary,
           public.normalize_recap_json(m.recap_json) as recap_json,
           m.kind, m.language, m.started_at, m.ended_at
    from public.meeting_shares s
    join public.meetings m on m.id = s.meeting_id
    where s.token = p_token
      and s.revoked_at is null
      and m.deleted_at is null;
$$;

revoke all on function public.normalize_recap_json(jsonb) from public;
revoke all on function public.get_shared_meeting(uuid)    from public;
grant execute on function public.get_shared_meeting(uuid) to anon, authenticated;
