-- Routing-policy telemetry for usage_events — PR 1 of the OpenRouter/model
-- migration plan. Additive only: `model` keeps its existing, already-queried
-- shape (including the `${provider}:${model}` tag on transcribe rows); these
-- columns are the honest, separate answer to "what did the client ask for",
-- "what actually served", "which routing category", and "against which
-- policy version" — none of which `model` alone can answer once server-side
-- routing starts remapping requests.

alter table public.usage_events
    add column if not exists task text,
    add column if not exists routing_version text,
    add column if not exists requested_model text,
    add column if not exists resolved_model text;

comment on column public.usage_events.task is
    'Routing category the call was for: stt, summary, title, utility, chat. Null on rows written before this column existed; "unknown" on rows from a client build old enough to not send it.';
comment on column public.usage_events.routing_version is
    'Server-side routing policy version active when this call was served — lets a cost/quality shift be pinned to the policy that caused it.';
comment on column public.usage_events.requested_model is
    'The model id the client asked for (or the server''s resolved default, once server-side routing exists).';
comment on column public.usage_events.resolved_model is
    'The model that actually served the request, when determinable — differs from requested_model when a fallback chain kicked in.';

-- "Which task costs the most, and is it trending" is the dashboard query
-- this whole PR exists for.
create index if not exists usage_events_task_created_idx
    on public.usage_events (task, created_at desc)
    where task is not null;
