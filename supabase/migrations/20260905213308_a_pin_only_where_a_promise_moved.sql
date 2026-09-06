-- Unpin the subscriptions that were never at risk.
--
-- `20260905203754` copied each active subscription's current ceiling into its own
-- `limit_overrides` before lowering Pro's, following the shape `20260802100544`
-- established. That is right for Pro, whose number moved. It is wrong for every
-- other plan: `resolve_entitlement` merges `limit_overrides` last, so a Starter
-- subscriber who happened to be active that day is now pinned to 8 hours
-- permanently, and no future change to `plans.limits.hours_per_month` will ever
-- reach them. `apply_paddle_subscription` only clears the pin on a plan change,
-- so nothing else would have removed it.
--
-- Only pins that still equal what their plan grants are removed, which is exactly
-- the set that carries no promise. A pin that differs from its plan is somebody's
-- grandfathered ceiling — 15 hours from `20260802100544`, or 40 from this branch
-- — and is left alone. A hand-set support override differs too, and survives for
-- the same reason.

update public.subscriptions as s
   set limit_overrides = s.limit_overrides - 'hours_per_month'
  from public.plans as p
 where p.plan = s.plan
   and s.limit_overrides ? 'hours_per_month'
   and p.limits ? 'hours_per_month'
   and (s.limit_overrides->>'hours_per_month')::numeric
       = (p.limits->>'hours_per_month')::numeric;
