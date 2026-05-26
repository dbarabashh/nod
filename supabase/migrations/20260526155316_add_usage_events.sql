-- Usage events — one row per LLM proxy call, captured server-side from the
-- OpenRouter upstream response. Drives:
--   1. per-user cost visibility (how much does an active user actually cost?)
--   2. quota enforcement for the free tier (#17)
--   3. pricing decisions for paid tiers
--
-- Chat rows carry token counts and the OpenRouter generation id (for
-- after-the-fact reconciliation via /api/v1/generation?id=...). Transcribe
-- rows carry the audio seconds we sent upstream — OpenRouter doesn't return
-- token usage for Whisper, so duration × per-model rate is the cost proxy.

create table public.usage_events (
    id             uuid        primary key default gen_random_uuid(),
    user_id        uuid        not null references auth.users(id) on delete cascade,
    created_at     timestamptz not null default now(),
    kind           text        not null check (kind in ('chat', 'transcribe')),
    model          text        not null,
    status         int         not null,

    -- Chat-only (NULL for transcribe).
    prompt_tokens     int,
    completion_tokens int,
    generation_id     text,

    -- Transcribe-only (NULL for chat).
    audio_seconds     numeric(10, 3),

    -- Populated when OpenRouter returns usage.cost (chat with `usage.include`)
    -- or when we backfill via /generation. NULL means cost unknown yet.
    cost_usd       numeric(12, 6)
);

-- "Show me this user's spend this month" — the dashboard query shape.
create index usage_events_user_created_idx
    on public.usage_events (user_id, created_at desc);

-- The proxy writes; the user reads their own rows (for future "usage" UI).
alter table public.usage_events enable row level security;

create policy "users read own usage"
    on public.usage_events
    for select
    to authenticated
    using (auth.uid() = user_id);

-- No insert policy for `authenticated` — the proxy writes with the service
-- role key, which bypasses RLS. Clients must not be able to forge usage rows.
