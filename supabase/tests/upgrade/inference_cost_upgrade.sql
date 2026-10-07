\set ON_ERROR_STOP on
begin;
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
do $$ begin
    if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated; end if;
end $$;
\ir ../../migrations/20260526155316_add_usage_events.sql
\ir ../../migrations/20260811110225_stt_failover_observability.sql
\ir ../../migrations/20260811130000_usage_events_routing_telemetry.sql
insert into auth.users(id) values ('00000000-0000-4000-8000-000000000001');
insert into public.usage_events(user_id,kind,model,status,cost_usd,completion_tokens)
values ('00000000-0000-4000-8000-000000000001','chat','legacy',200,0.01,40);
\ir ../../migrations/20261007114024_inference_cost_telemetry.sql
insert into public.usage_events(user_id,kind,model,status,cost_usd,completion_tokens)
values ('00000000-0000-4000-8000-000000000001','chat','legacy-after-upgrade',200,0.02,40);
insert into public.usage_events(user_id,kind,model,status,cost_usd,completion_tokens,purpose,meeting_id,reasoning_tokens,cached_tokens,resolved_model)
values ('00000000-0000-4000-8000-000000000001','chat','new',200,0.03,40,'recap','00000000-0000-4000-8000-000000000002',30,50,'actual-model');
do $$ begin
    if (select count(*) from public.usage_events) <> 3 then raise exception 'mixed writers failed'; end if;
    if (select count(*) from public.usage_events where reasoning_tokens is null) <> 2 then raise exception 'legacy unknown counts changed'; end if;
    if (select sum(cost_usd) from public.usage_events) <> 0.06 then raise exception 'legacy cost aggregation changed'; end if;
    if not (select relrowsecurity from pg_class where oid='public.usage_events'::regclass) then raise exception 'RLS lost'; end if;
    if not exists (select 1 from pg_policies where tablename='usage_events' and policyname='users read own usage') then raise exception 'policy lost'; end if;
    begin
        update public.usage_events set reasoning_tokens = -1 where model='new';
        raise exception 'negative count accepted';
    exception when check_violation then null;
    end;
end $$;
rollback;
