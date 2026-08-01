-- `screen_observations` landed in the same push that fixed the per-row
-- `auth.uid()` everywhere else, so its own four policies were created with the
-- pattern the other migration had just removed. This is the table that can least
-- afford it: ambient capture upserts every five seconds and every chat question
-- runs a text search over it.

alter policy "users read own screen observations"   on public.screen_observations using ((select auth.uid()) = user_id);
alter policy "users delete own screen observations" on public.screen_observations using ((select auth.uid()) = user_id);
alter policy "users insert own screen observations" on public.screen_observations with check ((select auth.uid()) = user_id);
alter policy "users update own screen observations" on public.screen_observations
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
