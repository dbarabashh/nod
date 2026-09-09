-- Unticking a task now goes through `move`, which writes `loop_state` and lets
-- the trigger derive `done`. The trigger cleared `done` but left `done_at`, so a
-- reopened loop kept the moment it was "finished" — a date on a row that is not
-- done, and one the next reader has no way to know is stale.
create or replace function public.action_items_sync_loop_state()
returns trigger
language plpgsql
as $$
begin
    if tg_op = 'UPDATE' then
        -- The person ticked the box: that is a confirmation, whatever we thought.
        if new.done is distinct from old.done then
            new.loop_state := case when new.done then 'confirmed' else 'open' end;
        -- We moved the state: `done` follows, so an old client still reads it right.
        elsif new.loop_state is distinct from old.loop_state then
            new.done := new.loop_state = 'confirmed';
            if new.done then
                new.done_at := coalesce(new.done_at, now());
            else
                new.done_at := null;
            end if;
        end if;
    elsif tg_op = 'INSERT' and new.done and new.loop_state = 'open' then
        new.loop_state := 'confirmed';
    end if;
    return new;
end $$;
