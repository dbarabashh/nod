-- 1. `_user_last_active` shipped as SECURITY DEFINER taking an arbitrary user id,
--    with no `_assert_founder()` and a grant to `authenticated` — and, because
--    Postgres grants EXECUTE to PUBLIC by default, to `anon` as well. Any caller
--    could read another account's activity through /rest/v1/rpc, bypassing RLS.
--    It is an internal helper: the founder RPCs that call it are themselves
--    definer-owned, so they need no grant at all.
-- 2. `founder_users_enriched` was recreated by drop+create in the previous
--    migration, which reset its grants to the PUBLIC default and undid the
--    revoke every other founder RPC carries.
-- 3. The founder guard itself ran with a mutable search_path.
-- 4. Every per-user RLS policy re-evaluated `auth.uid()` per row instead of once.

revoke all on function public._user_last_active(uuid) from public, anon, authenticated;
revoke all on function public.founder_users_enriched(int, int) from public, anon;

create or replace function public._founder_emails()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['dmytro@hellonod.app', 'viktoriia@hellonod.app'];
$$;

create or replace function public.is_founder()
returns boolean
language sql
stable
set search_path = ''
as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) = any (
    array['dmytro@hellonod.app', 'viktoriia@hellonod.app']
  );
$$;

create or replace function public._assert_founder()
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if not public.is_founder() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
end;
$$;

-- `auth.uid()` in a policy body is evaluated once per row. Wrapping it in a
-- scalar subquery turns it into an InitPlan, evaluated once per statement.
-- Same predicate, same rows — this changes cost, never access.

alter policy "users read own action_items"   on public.action_items using ((select auth.uid()) = user_id);
alter policy "users update own action_items" on public.action_items using ((select auth.uid()) = user_id);
alter policy "users delete own action_items" on public.action_items using ((select auth.uid()) = user_id);
alter policy "users insert own action_items" on public.action_items with check ((select auth.uid()) = user_id);

alter policy "users read own chat"   on public.chat_messages using ((select auth.uid()) = user_id);
alter policy "users delete own chat" on public.chat_messages using ((select auth.uid()) = user_id);
alter policy "users insert own chat" on public.chat_messages with check ((select auth.uid()) = user_id);

alter policy "owners read own connections"   on public.connections using ((select auth.uid()) = user_id);
alter policy "owners update own connections" on public.connections using ((select auth.uid()) = user_id);
alter policy "owners insert own connections" on public.connections with check ((select auth.uid()) = user_id);

alter policy "users read own consent rows"   on public.consent_acknowledgements using ((select auth.uid()) = user_id);
alter policy "users insert own consent rows" on public.consent_acknowledgements with check ((select auth.uid()) = user_id);

alter policy "users read own entities"   on public.entities using ((select auth.uid()) = user_id);
alter policy "users update own entities" on public.entities using ((select auth.uid()) = user_id);
alter policy "users insert own entities" on public.entities with check ((select auth.uid()) = user_id);

alter policy "users read own knowledge messages"   on public.knowledge_messages using ((select auth.uid()) = user_id);
alter policy "users delete own knowledge messages" on public.knowledge_messages using ((select auth.uid()) = user_id);
alter policy "users insert own knowledge messages" on public.knowledge_messages with check ((select auth.uid()) = user_id);

alter policy "users read own knowledge threads"   on public.knowledge_threads using ((select auth.uid()) = user_id);
alter policy "users delete own knowledge threads" on public.knowledge_threads using ((select auth.uid()) = user_id);
alter policy "users update own knowledge threads" on public.knowledge_threads
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
alter policy "users insert own knowledge threads" on public.knowledge_threads with check ((select auth.uid()) = user_id);

alter policy "users read own labels"   on public.labels using ((select auth.uid()) = user_id);
alter policy "users update own labels" on public.labels using ((select auth.uid()) = user_id);
alter policy "users delete own labels" on public.labels using ((select auth.uid()) = user_id);
alter policy "users insert own labels" on public.labels with check ((select auth.uid()) = user_id);

alter policy "users read own meeting_entities"   on public.meeting_entities using ((select auth.uid()) = user_id);
alter policy "users delete own meeting_entities" on public.meeting_entities using ((select auth.uid()) = user_id);
alter policy "users insert own meeting_entities" on public.meeting_entities with check ((select auth.uid()) = user_id);

alter policy "users read own meeting_labels"   on public.meeting_labels using ((select auth.uid()) = user_id);
alter policy "users delete own meeting_labels" on public.meeting_labels using ((select auth.uid()) = user_id);
alter policy "users insert own meeting_labels" on public.meeting_labels with check (
  (select auth.uid()) = user_id
  and exists (select 1 from public.meetings m where m.id = meeting_labels.meeting_id and m.user_id = (select auth.uid()))
  and exists (select 1 from public.labels l where l.id = meeting_labels.label_id and l.user_id = (select auth.uid()))
);

alter policy "owners read own shares"   on public.meeting_shares using ((select auth.uid()) = created_by);
alter policy "owners update own shares" on public.meeting_shares using ((select auth.uid()) = created_by);
alter policy "owners delete own shares" on public.meeting_shares using ((select auth.uid()) = created_by);
alter policy "owners create own shares" on public.meeting_shares with check (
  (select auth.uid()) = created_by
  and exists (
    select 1 from public.meetings m
    where m.id = meeting_shares.meeting_id and m.user_id = (select auth.uid()) and m.deleted_at is null
  )
);

alter policy "users read own transcripts"   on public.meeting_transcripts using ((select auth.uid()) = user_id);
alter policy "users delete own transcripts" on public.meeting_transcripts using ((select auth.uid()) = user_id);
alter policy "users insert own transcripts" on public.meeting_transcripts with check (
  (select auth.uid()) = user_id
  and exists (select 1 from public.meetings m where m.id = meeting_transcripts.meeting_id and m.user_id = (select auth.uid()))
);
alter policy "users update own transcript speakers" on public.meeting_transcripts
  using (
    (select auth.uid()) = user_id
    and exists (select 1 from public.meetings m where m.id = meeting_transcripts.meeting_id and m.user_id = (select auth.uid()))
  )
  with check (
    (select auth.uid()) = user_id
    and exists (select 1 from public.meetings m where m.id = meeting_transcripts.meeting_id and m.user_id = (select auth.uid()))
  );

alter policy "users read own meetings"         on public.meetings using ((select auth.uid()) = user_id and deleted_at is null);
alter policy "users read own trashed meetings" on public.meetings using ((select auth.uid()) = user_id and deleted_at is not null);
alter policy "users update own meetings"       on public.meetings using ((select auth.uid()) = user_id);
alter policy "users delete own meetings"       on public.meetings using ((select auth.uid()) = user_id);
alter policy "users insert own meetings"       on public.meetings with check ((select auth.uid()) = user_id);

alter policy "users read own onboarding events"   on public.onboarding_events using ((select auth.uid()) = user_id);
alter policy "users insert own onboarding events" on public.onboarding_events with check ((select auth.uid()) = user_id);

alter policy "users read own profile"   on public.profiles using ((select auth.uid()) = user_id);
alter policy "users update own profile" on public.profiles using ((select auth.uid()) = user_id);
alter policy "users insert own profile" on public.profiles with check ((select auth.uid()) = user_id);

alter policy "users read own retrieval feedback"   on public.retrieval_feedback using ((select auth.uid()) = user_id);
alter policy "users delete own retrieval feedback" on public.retrieval_feedback using ((select auth.uid()) = user_id);
alter policy "users insert own retrieval feedback" on public.retrieval_feedback with check ((select auth.uid()) = user_id);

alter policy "users read own embeddings"   on public.session_embeddings using ((select auth.uid()) = user_id);
alter policy "users delete own embeddings" on public.session_embeddings using ((select auth.uid()) = user_id);
alter policy "users insert own embeddings" on public.session_embeddings with check ((select auth.uid()) = user_id);

alter policy "users read own usage" on public.usage_events using ((select auth.uid()) = user_id);

alter policy founder_all on public.founder_hypotheses    using ((select public.is_founder())) with check ((select public.is_founder()));
alter policy founder_all on public.founder_manual_inputs using ((select public.is_founder())) with check ((select public.is_founder()));
alter policy founder_all on public.founder_user_notes    using ((select public.is_founder())) with check ((select public.is_founder()));

-- Every one of these is the column an RLS policy filters on and the column an
-- account deletion cascades through, so an unindexed FK is a sequential scan on
-- the hot path twice over.
create index if not exists chat_messages_user_idx        on public.chat_messages (user_id);
create index if not exists knowledge_messages_user_idx   on public.knowledge_messages (user_id);
create index if not exists meeting_entities_user_idx     on public.meeting_entities (user_id);
create index if not exists meeting_labels_user_idx       on public.meeting_labels (user_id);
create index if not exists meeting_transcripts_user_idx  on public.meeting_transcripts (user_id);
create index if not exists session_embeddings_user_idx   on public.session_embeddings (user_id);
create index if not exists retrieval_feedback_meeting_idx on public.retrieval_feedback (meeting_id);
create index if not exists plan_prices_plan_idx          on public.plan_prices (plan);
create index if not exists subscriptions_plan_idx        on public.subscriptions (plan);
