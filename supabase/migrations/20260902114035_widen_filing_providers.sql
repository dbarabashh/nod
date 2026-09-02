-- A filed action item points back at the product it landed in, and a proposal
-- names the product and action it would run. Both lists were written when Linear
-- was the only tracker and never widened when Jira and Asana joined: a Jira or
-- Asana filing succeeds at the provider and then fails to be recorded here, and
-- a proposal for either is refused before anybody sees it. Google Tasks joins
-- the trackers with this migration, so the lists move to what the client can
-- actually produce.
--
-- The pointer accepts any provider the broker can reach — the same shape
-- `integration_connections.provider` has accepted since `20260824210000` — so
-- the next tracker does not need a migration to be filed into. Proposal types
-- stay an explicit list on purpose: what a meeting may propose is a product
-- decision per action, not per provider.

alter table public.action_items
    drop constraint action_items_external_provider_check;

alter table public.action_items
    add constraint action_items_external_provider_check
    check (external_provider is null or external_provider ~ '^[a-z0-9][a-z0-9_-]{0,62}$');

alter table public.action_proposals
    drop constraint action_proposals_type_check;

alter table public.action_proposals
    add constraint action_proposals_type_check
    check (type in (
        'linear.create_issue',
        'linear.update_issue',
        'jira.create_issue',
        'jira.update_issue',
        'asana.create_task',
        'asana.update_task',
        'google-tasks.create_task',
        'google-tasks.update_task',
        'google-calendar.create_event',
        'slack.create_channel',
        'slack.invite_users'
    ));
