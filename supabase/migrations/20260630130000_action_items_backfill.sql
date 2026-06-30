-- One-time backfill: promote action items already captured in each meeting's
-- `recap_json` into first-class `action_items` rows, so existing users see past
-- meetings' to-dos in the new checklist. Idempotent (skips any meeting that
-- already has rows) and runs once per environment as migrations apply.
--
-- Past recaps store action items in TWO older shapes — there is no top-level
-- `action_items` array yet (that ships with this release), so we read both:
--
--   1. Legacy `actions` array — `{owner, task, when}`. Object elements only
--      (some arrays carry stray scalars); owner is folded into the text, `when`
--      becomes the free-text deadline. This mirrors MeetingRecap.legacyActions.
--   2. `sections` array — bullets of a section whose title is an action heading.
--      Titles are multilingual, so the match is an ANCHORED full-title set built
--      from the real data (a loose `~ 'azioni'` wrongly caught "assegnazioni"
--      and past-tense "azioni intraprese"/"decisioni e azioni"). No separate
--      deadline in this shape — it's embedded in the bullet text.
--
-- Scope: every non-`media` meeting (media is passive listening with no personal
-- to-dos — see SessionKind.extractsActionItems). A meeting carries exactly one
-- of the two shapes, so per-meeting positions stay contiguous and unique,
-- satisfying the partial-unique index on (meeting_id, position).
insert into public.action_items (user_id, meeting_id, text, deadline, position)
with extracted as (
    select
        m.user_id,
        m.id as meeting_id,
        case when coalesce(trim(a->>'owner'), '') = '' then trim(a->>'task')
             else trim(a->>'owner') || ' — ' || trim(a->>'task') end as text,
        nullif(trim(coalesce(a->>'when', '')), '') as deadline,
        ord::numeric as ord_key,
        0 as branch
    from public.meetings m
    cross join lateral jsonb_array_elements(
        case jsonb_typeof(m.recap_json -> 'actions')
            when 'array' then m.recap_json -> 'actions' else '[]'::jsonb end
    ) with ordinality as t(a, ord)
    where m.kind <> 'media'
      and m.deleted_at is null
      and jsonb_typeof(a) = 'object'
      and coalesce(trim(a->>'task'), '') <> ''

    union all

    select
        m.user_id,
        m.id as meeting_id,
        trim(b->>'text') as text,
        null::text as deadline,
        (sec_ord * 1000 + b_ord)::numeric as ord_key,
        1 as branch
    from public.meetings m
    cross join lateral jsonb_array_elements(
        case jsonb_typeof(m.recap_json -> 'sections')
            when 'array' then m.recap_json -> 'sections' else '[]'::jsonb end
    ) with ordinality as sx(sec, sec_ord)
    cross join lateral jsonb_array_elements(
        case jsonb_typeof(sec -> 'bullets')
            when 'array' then sec -> 'bullets' else '[]'::jsonb end
    ) with ordinality as t(b, b_ord)
    where m.kind <> 'media'
      and m.deleted_at is null
      and jsonb_typeof(b) = 'object'
      and coalesce(trim(b->>'text'), '') <> ''
      and lower(trim(sec->>'title')) ~
          '^(action items?|next steps?|to-?dos?|follow.?ups?|action plan|elementi d.azione|azioni in sospeso|azioni da fare|prossimi passi|наступні кроки|подальші кроки|próximos pasos|nächste schritte)$'
),
numbered as (
    select
        user_id, meeting_id, text, deadline,
        (row_number() over (partition by meeting_id order by branch, ord_key) - 1)::int as position
    from extracted
)
select user_id, meeting_id, text, deadline, position
from numbered n
where not exists (
    select 1 from public.action_items ai where ai.meeting_id = n.meeting_id
);
