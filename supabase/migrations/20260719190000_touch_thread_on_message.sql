-- `updated_at` is what the Ask Nod list orders by, and the client was keeping it
-- current with a second request after every message insert — two extra round
-- trips per turn, both stamping the device's clock. A machine whose clock runs
-- fast would pin its threads to the top of the list forever, which is the same
-- reason the insert payload omits the column and lets `default now()` win.
--
-- The database is the only party that can stamp this correctly, and it already
-- knows when a message lands.
create or replace function public.touch_knowledge_thread()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.knowledge_threads
       set updated_at = now()
     where id = new.thread_id;
    return new;
end;
$$;

create trigger knowledge_messages_touch_thread
    after insert on public.knowledge_messages
    for each row
    execute function public.touch_knowledge_thread();
