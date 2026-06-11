-- Trial is capped to 1 device, like Starter. The trial seeded with Pro's
-- limits (3 devices), but a no-card trial that unlocks 3 machines invites
-- account sharing before any payment signal exists. Features stay the full
-- Pro set; only the device limit tightens. claim_device and
-- resolve_entitlement both read plans.limits, so this UPDATE is the whole
-- change.

update public.plans
set limits = limits || '{"devices": 1}'::jsonb
where plan = 'trial';
