-- What a connection leaves behind when it ends.
--
-- Disconnecting is about to become a button, and a button that stops the reading
-- while leaving a week of somebody's meeting titles in our database is not the
-- thing they pressed.
--
-- On the connection rather than in the function that revokes it. There are three
-- ways a connection can end — the button, Nango's webhook when the grant is
-- withdrawn at Google, and an operator deleting the row — and only one of them
-- would ever remember to call a cleanup. The row going away is the event that
-- matters, so that is what this hangs on.
--
-- Only fires on the transition into revoked. An update that touches anything
-- else on an already-revoked row is not a second disconnection.

create function public._purge_provider_data()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_user     uuid;
    v_provider text;
begin
    if tg_op = 'DELETE' then
        v_user := old.user_id;
        v_provider := old.provider;
    elsif new.revoked_at is not null and old.revoked_at is null then
        v_user := new.user_id;
        v_provider := new.provider;
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

    return null;
end;
$$;

revoke all on function public._purge_provider_data() from public, anon, authenticated;

create trigger purge_provider_data
    after update or delete on public.integration_connections
    for each row execute function public._purge_provider_data();
