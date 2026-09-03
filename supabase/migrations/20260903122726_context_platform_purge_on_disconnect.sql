-- Extends the existing disconnect-purge trigger (`_purge_provider_data`,
-- `20260815145530_purge_data_on_disconnect.sql`) to the context platform:
-- disconnecting a provider now also deletes that connection's
-- `source_objects` — `source_object_versions` and `source_chunks` cascade
-- off it automatically (`on delete cascade`). This is the answer to the
-- plan's §14 retention question #4 (source bodies deleted immediately on
-- disconnect), matching the product's existing default for every other
-- provider already wired here rather than inventing a second policy.
--
-- Keyed on the connection's own id, not `(user_id, provider)` like the
-- google-calendar block above it: `source_objects.connection_id` points at
-- one specific `integration_connections` row, which is the more precise
-- match once a user can hold more than one connection to the same provider.
create or replace function public._purge_provider_data()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_user       uuid;
    v_provider   text;
    v_connection uuid;
begin
    if tg_op = 'DELETE' then
        v_user := old.user_id;
        v_provider := old.provider;
        v_connection := old.id;
    elsif new.revoked_at is not null and old.revoked_at is null then
        v_user := new.user_id;
        v_provider := new.provider;
        v_connection := new.id;
    else
        return null;
    end if;

    -- Linear stores nothing here: a filed issue lives in Linear, and the link on
    -- an action item is the user's own record of where their work went.
    if v_provider = 'google-calendar' then
        delete from public.calendar_events
         where user_id = v_user and provider = v_provider;
        delete from public.calendar_sync_state
         where user_id = v_user and provider = v_provider;
    end if;

    delete from public.source_objects where connection_id = v_connection;

    return null;
end;
$$;
