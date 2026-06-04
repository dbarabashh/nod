-- Reshape the profile from work-specific facts (role / focus) to durable,
-- cross-context preferences. A global profile is injected into EVERY session,
-- but "where you work / what project" is only true for some of them — noise
-- for a therapy session or a side-project call, and stale within weeks. The
-- `preferences` field instead captures what the user always wants from Nod
-- (e.g. "pull out what I committed to, keep it short"), which improves every
-- session regardless of what it's about. Per-session context now lives in
-- labels + the entity/knowledge graph the app already learns from recordings.

alter table public.profiles add column preferences text;

-- Preserve anything users already entered: fold role + focus into preferences.
update public.profiles
set preferences = nullif(
    trim(both ' ' from concat_ws(' — ', nullif(role, ''), nullif(focus, ''))),
    ''
)
where preferences is null
  and (coalesce(role, '') <> '' or coalesce(focus, '') <> '');

alter table public.profiles drop column role;
alter table public.profiles drop column focus;
