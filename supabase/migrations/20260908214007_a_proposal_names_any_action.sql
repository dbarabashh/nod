-- A proposal names any `provider.action` the registry can dispatch.
--
-- `20260902114035` kept the type list explicit on the theory that what a
-- meeting may propose is a product decision per action. It was also the third
-- migration in a row whose only job was to widen that list, and the fourth
-- tracker would have been the fourth. The decision the list was guarding is
-- now made where it is enforced: `proposal-execute` runs only what `registry`
-- has a handler for, and the org's own allow-list (`20260816240000`) says which
-- providers a proposal may reach. The constraint keeps the shape and nothing
-- else, so the next adapter needs no migration to be proposed into.
--
-- `capability` is the verb's family — the thing the client shows a person as
-- one choice with a default product behind it. Nullable and backfilled from
-- the prefix for the rows already here; nothing sets it yet, so a reader must
-- treat null as "not classified", not as "none".
--
-- Expand only. Every value the old constraint accepted passes the new one, and
-- `agents.draft_type` keeps its own, narrower check.

alter table public.action_proposals
    drop constraint if exists action_proposals_type_check;

alter table public.action_proposals
    add constraint action_proposals_type_check
    check (type ~ '^[a-z0-9-]+\.[a-z0-9_]+$');

alter table public.action_proposals
    add column capability text
    check (capability is null or capability in (
        'tasks', 'conversations', 'calendar', 'documents', 'email', 'customers'
    ));

update public.action_proposals
set capability = case split_part(type, '.', 1)
    when 'linear' then 'tasks'
    when 'jira' then 'tasks'
    when 'asana' then 'tasks'
    when 'google-tasks' then 'tasks'
    when 'google-calendar' then 'calendar'
    when 'slack' then 'conversations'
    when 'hubspot' then 'customers'
    when 'notion' then 'documents'
    when 'google-drive' then 'documents'
    when 'gmail' then 'email'
end
where capability is null;
