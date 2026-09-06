-- `20260808121725_product_analytics` gave `meeting_shares` an `id` and hung
-- `share_product_events.share_id` off it. Production has both; the sandbox
-- lost the column outside any migration, which took the unique constraint
-- and the foreign key with it and left `record_share_view` selecting a column
-- that is not there. Written to be a no-op where the schema is already right,
-- so the same file converges every environment on what the migration meant.

alter table public.meeting_shares
    add column if not exists id uuid not null default gen_random_uuid();

do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.meeting_shares'::regclass
          and conname = 'meeting_shares_id_key'
    ) then
        alter table public.meeting_shares
            add constraint meeting_shares_id_key unique (id);
    end if;

    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.share_product_events'::regclass
          and conname = 'share_product_events_share_id_fkey'
    ) then
        alter table public.share_product_events
            add constraint share_product_events_share_id_fkey
            foreign key (share_id) references public.meeting_shares(id) on delete cascade;
    end if;
end;
$$;
