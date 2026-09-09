-- Integrations become a thing a plan grants.
--
-- Until now nothing gated a connection: no key in `plans.features`, no check in
-- `IntegrationsSection`, and none in `integration-connect`, `connect` or
-- `integration-action`. A Starter subscriber could connect anything, and the
-- paywall's comparison row said so by drawing the same logos in every column —
-- accurately, and not at all the way NOD-138 prices it.
--
-- NOD-138 asks for two tiers and contradicts itself about them. Its feature table
-- gives Starter "Core personal connections" and Pro "All personal connections",
-- while the Integrations rule underneath says "Starter and Pro: personal
-- connections" as though they were the same. The rest of the table settles it:
-- Calendar awareness and "Notion and Google Docs export" are both listed as
-- Included on Starter, and the row that distinguishes the tiers is named "Jira,
-- Linear, and personal integrations". So the split is the calendar and the two
-- export destinations on Starter, and the tools you work a ticket in on Pro.
--
-- Two keys rather than one per provider. Which provider sits in which tier is a
-- property of the provider, and it lives in the Edge Functions' own registry
-- beside the broker slug and the API base — the file that already says "adding
-- an integration is one import and one entry here". What the plan carries is only
-- how far somebody is allowed to reach.
--
-- `integrations_all` is a superset in meaning but not in membership: a plan
-- carries both keys so a reader never has to know the ordering, and a check for
-- the core tier is a check for one key rather than for either of two.

update public.plans
   set features = features || array['integrations_core']
 where plan = 'starter'
   and not ('integrations_core' = any (features));

update public.plans
   set features = features || array['integrations_core', 'integrations_all']
 where plan in ('trial', 'pro', 'teams')
   and not ('integrations_all' = any (features));
