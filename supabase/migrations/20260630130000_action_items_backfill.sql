-- One-time backfill: promote action items already captured inside each
-- meeting's `recap_json` into first-class `action_items` rows, so existing
-- users see their past meetings' to-dos in the new checklist without having to
-- re-generate a recap. Idempotent and runs once per environment as migrations
-- apply (sandbox on the develop push, prod on the main merge).
--
-- Scope: every non-`media` meeting (media is passive listening with no personal
-- to-dos — see SessionKind.extractsActionItems). Skipped wholesale for any
-- meeting that already has rows (even soft-deleted ones), so a re-run, the
-- finalize-time save, or a task the user already deleted is never duplicated or
-- resurrected — matching ActionItemStore's own guard.
insert into public.action_items (user_id, meeting_id, text, deadline, position)
select
    m.user_id,
    m.id,
    trim(elem->>'text'),
    nullif(trim(coalesce(elem->>'deadline', '')), ''),
    (ord - 1)::int
from public.meetings m
cross join lateral jsonb_array_elements(
    case jsonb_typeof(m.recap_json -> 'action_items')
        when 'array' then m.recap_json -> 'action_items'
        else '[]'::jsonb
    end
) with ordinality as t(elem, ord)
where m.kind <> 'media'
  and m.deleted_at is null
  and coalesce(trim(elem->>'text'), '') <> ''
  and not exists (
      select 1 from public.action_items ai where ai.meeting_id = m.id
  );
