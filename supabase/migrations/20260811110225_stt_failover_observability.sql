alter table public.usage_events
    add column if not exists failover jsonb;

comment on column public.usage_events.failover is
    'STT provider attempts that failed before the serving one, oldest first: [{provider, status, reason, ms, retry_after, body}]. Null when the first provider served.';

create index if not exists usage_events_failover_idx
    on public.usage_events using gin (failover)
    where failover is not null;
