-- Bring plan entitlements in line with the published pricing table, without
-- taking anything away from anyone who already subscribed.
--
-- Hours. `resolve_entitlement` reads `plans.limits->>'hours_per_month'` merged
-- over `subscriptions.limit_overrides` (the override wins), so this table is the
-- only lever. The old numbers were 15 (starter) / 50 (pro), plus a trial cap of
-- 50 that made the advertised "14 days or 5 hours" fiction — one trial spent
-- 15.4 hours. Measured cost is $0.163 per wall-hour of STT plus $0.0279 per LLM
-- call, which lands at $0.406/h for the median user and $0.574/h for the worst
-- observed profile (short meetings + heavy Ask Nod). Prices are unchanged and
-- ~79% of a yearly price reaches us after VAT and the Paddle fee ($7.08/mo on
-- starter, $15.00/mo on pro).
--
-- Starter's 8 is therefore a real ceiling: it is the most that still clears ~35%
-- margin against the worst profile.
--
-- Pro's 40 is a different kind of number. Pro is sold as unlimited, so 40 is not
-- priced to be profitable at the limit — it is the point where usage stops
-- looking like one person and the fair-use terms apply. It is 2.6x the largest
-- month ever recorded on any plan (15.4 hours, a trial) and ~6x the p90 paying
-- user; the largest Pro month to date is 6.2. Reaching it would cost us about $8
-- a month over the subscription, which is the bounded price of the claim —
-- against an unbounded one if no ceiling existed at all.
--
-- Grandfathering runs FIRST and in the same transaction, so nobody is ever
-- resolved against the new ceiling: every already-subscribed row keeps the hours
-- it was sold by having them pinned into its own `limit_overrides`. Writing it
-- as "copy whatever the plan currently grants" rather than a hardcoded 15/50
-- keeps it correct on any branch, whose plan rows and subscriber sets differ.
--
-- Trials are deliberately NOT grandfathered: the page has always said 5 hours,
-- so lowering the cap makes the promise true rather than breaking one, and
-- trials are 79% of all inference spend.
--
-- action_items on starter. The pricing page promises "summaries & action items"
-- on both plans, and granting it costs nothing: the recap prompt returns
-- `action_items` inside the same LLM call that produces the summary
-- (`PromptLibrary+Recap.swift`), so the flag only decides whether the client
-- renders them. No plan loses a feature here, so `feature_overrides` needs no
-- equivalent pinning.

update public.subscriptions as s
   set limit_overrides = coalesce(s.limit_overrides, '{}'::jsonb)
                         || jsonb_build_object('hours_per_month',
                                               (p.limits->>'hours_per_month')::numeric)
  from public.plans as p
 where p.plan = s.plan
   and s.status in ('active', 'past_due')
   and p.limits ? 'hours_per_month'
   -- Never clobber a ceiling someone already set by hand.
   and not (coalesce(s.limit_overrides, '{}'::jsonb) ? 'hours_per_month');

update public.plans as p
   set limits = jsonb_set(p.limits, '{hours_per_month}', to_jsonb(v.hours))
  from (values ('trial', 5), ('starter', 8), ('pro', 40)) as v (plan, hours)
 where p.plan = v.plan
   and p.limits->>'hours_per_month' is distinct from v.hours::text;

-- Pro is sold as "unlimited meeting hours", bounded only by the fair-use terms
-- (`docs/policies/terms.md` § 7). The 40 above is what that bound actually is:
-- an internal ceiling for enforcement and alerting, never a number we show.
--
-- A separate flag rather than a sentinel value, because every reader would
-- otherwise have to agree on which magic number means "don't render this" — and
-- the one that forgets prints "40 meeting hours / month" next to a page
-- promising unlimited. `hours_per_month` stays the truth for metering; this
-- decides only whether a surface prints it.
alter table public.plans
  add column if not exists hours_are_unlimited boolean not null default false;

update public.plans set hours_are_unlimited = true  where plan = 'pro'  and not hours_are_unlimited;
update public.plans set hours_are_unlimited = false where plan <> 'pro' and hours_are_unlimited;

update public.plans
   set features = array_append(features, 'action_items')
 where plan = 'starter'
   and not ('action_items' = any (features));
