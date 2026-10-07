alter table public.usage_events
    add column purpose text,
    add column meeting_id uuid,
    add column reasoning_tokens integer check (reasoning_tokens >= 0),
    add column cached_tokens integer check (cached_tokens >= 0);
