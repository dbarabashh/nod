-- An action item that has been filed in a connected product carries a pointer
-- back to it, so the surface that offered "file this" can show "filed" instead
-- and stop offering it a second time.
--
-- Plain columns rather than a jsonb blob: "is this already in Linear" is a
-- query we will want to answer, and the identifier is what a person reads.
alter table public.action_items
    add column external_provider text
        check (external_provider is null or external_provider in ('linear')),
    add column external_key text,
    add column external_url text,
    add column external_created_at timestamptz;

-- All four travel together or none do — a pointer missing its identifier is a
-- row that renders as filed and links nowhere.
alter table public.action_items
    add constraint action_items_external_ref_complete check (
        (external_provider is null
            and external_key is null
            and external_url is null
            and external_created_at is null)
        or (external_provider is not null
            and external_key is not null
            and external_url is not null
            and external_created_at is not null)
    );

-- The owner files their own items; nothing else writes these columns. The
-- existing owner policies on `action_items` already scope the update.
