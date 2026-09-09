-- Pro goes back to being sold without a ceiling.
--
-- `20260905203754_pro_publishes_its_hours` replaced Pro's "unlimited (fair use)"
-- promise with a published 20-hour allowance. Its own header says it must not
-- reach production before NOD-138 was approved and `docs/pricing.md`, the
-- landing page and `terms.md` § 7 moved with it. Nothing enforced that: the
-- migration travelled to prod with an unrelated merge, and prod has since been
-- selling 20 hours at the $24/$240 price that was approved for unlimited.
--
-- That combination is in no approved catalog. NOD-138 pairs 25 hours with
-- $29/$288, and the catalog approved on 2026-08-12 pairs unlimited with
-- $24/$240. This restores the second one, because that is the offer the price
-- on the storefront was approved for. Moving to NOD-138 is a price change and
-- belongs to its own rollout.
--
-- Only the plan row moves. Every subscription that predates 09-05 already
-- carries its own `hours_are_unlimited` and `limit_overrides.hours_per_month`,
-- pinned there by the migration this reverses so those customers would keep the
-- promise they bought — including one hand-set 50-hour ceiling. Clearing a pin
-- here would take a grant away from the very rows it was written to protect, so
-- nothing is unpinned. A subscription created after 09-05 has no pin and follows
-- the plan, which is what this changes.
--
-- 40 is the fair-use bound `20260802100544` set, and `docs/pricing.md` derives
-- it. It does not gate anything while `hours_are_unlimited` is true —
-- `can_start_meeting` reads the flag — so it is where fair use sits, not a limit.
--
-- Teams keeps its 25 pooled hours. It was never part of the approved unlimited
-- offer, and no Paddle price makes it purchasable on prod yet.
--
-- Deploy order: the landing page went first (nod-landing `7fc7673`), so between
-- that push and this migration the pricing page promises unlimited while the
-- server still stops a new Pro subscriber at 20 hours. That order is deliberate.
-- Both directions of the gap are wrong, and they are not equally wrong: the page
-- was advertising a 20-hour allowance at the price approved for unlimited, which
-- is an offer no catalogue contains and which we would have to honour if someone
-- bought it. Promising more than the server enforces costs at most a pack offer
-- shown to a subscriber this migration then un-stops, and the page is one push to
-- revert; the other way round is a claim we cannot defend to a customer who
-- already paid. Apply this promptly and the window closes.

update public.plans
   set limits = jsonb_set(limits, '{hours_per_month}', to_jsonb(40)),
       hours_are_unlimited = true
 where plan = 'pro';
