-- Make ambient (screen) context a paid capability.
--
-- The pricing page has sold "Screen context — ask about what's in front of you"
-- as Pro-only since the landing redesign, but nothing enforced it: there was no
-- feature key at all, the llm-proxy gate covers only the three `search` scopes,
-- and `screen_observations` RLS checked ownership alone. Every plan had it,
-- including trials already past `trial_ends_at`.
--
-- The client writes `screen_observations` straight through PostgREST, so RLS is
-- the only real chokepoint — a gate in the app is UX, and this one costs money
-- (an upsert every five seconds, plus the embeddings and the larger chat
-- prompts those rows feed).
--
-- Only INSERT and UPDATE are gated. Read and delete stay open on purpose:
-- captures taken while the feature was ungated are the user's own data, and
-- someone who drops to Starter should still be able to see and erase what Nod
-- already stored rather than have it turn invisible. Blocking writes is what
-- stops the spend — the table stops growing and retention prunes the rest.

-- Mirrors `resolve_entitlement`'s notion of "active" exactly, including the
-- expired-trial case (status stays 'trialing' while `trial_ends_at` is in the
-- past, and that must NOT grant anything), and layers `feature_overrides` over
-- the plan the same way.
--
-- Deliberately NOT security definer, unlike the founder helpers: both tables it
-- reads are already RLS-protected for the caller (`users read own subscription`,
-- `authenticated read plans`), so an invoker function can only ever answer for
-- the caller's own row. That removes the escalation footgun that
-- 20260723130000_harden_definer_grants_and_rls had to clean up, where a definer
-- helper taking an id let any caller ask about another account.
create or replace function public.has_feature(p_feature text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
      from public.subscriptions s
      join public.plans p on p.plan = s.plan
     where s.user_id = (select auth.uid())
       and (
             s.status = 'active'
             or (
                  s.status = 'trialing'
                  and (s.trial_ends_at is null or now() <= s.trial_ends_at)
                )
           )
       and p_feature = any (
             coalesce(p.features, '{}') || coalesce(s.feature_overrides, '{}')
           )
  );
$$;

revoke all on function public.has_feature(text) from public, anon;
grant execute on function public.has_feature(text) to authenticated;

update public.plans
   set features = array_append(features, 'ambient_context')
 where plan in ('trial', 'pro')
   and not ('ambient_context' = any (features));

-- Wrapped in scalar subqueries so both stay InitPlans — evaluated once per
-- statement, not once per row. This table takes the highest write rate in the
-- schema, which is why 20260723140000 had to fix exactly this on it.
alter policy "users insert own screen observations" on public.screen_observations
  with check (
    (select auth.uid()) = user_id
    and (select public.has_feature('ambient_context'))
  );

alter policy "users update own screen observations" on public.screen_observations
  using ((select auth.uid()) = user_id)
  with check (
    (select auth.uid()) = user_id
    and (select public.has_feature('ambient_context'))
  );
