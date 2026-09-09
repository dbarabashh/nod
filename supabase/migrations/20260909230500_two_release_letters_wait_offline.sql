-- The two release letters, wired as campaigns and left switched off.
--
-- `winback-release-reactivation-v1-en` goes to the trials that
-- `20260909224615_an_expired_trial_gets_another_fourteen` brought back;
-- `release-update-active-v1-en` goes to everyone who was already paying or
-- already had a live trial. Neither sends anything on its own: both rows land
-- `is_enabled = false`, so arming them is one deliberate UPDATE.
--
-- Consent. Both carry an empty `required_topics`, which means the consent loop
-- in `email_campaign_qualification` does not run for them, and each branch
-- states the rule itself: everyone who has not explicitly said no to
-- `product_updates`. This is deliberate and it is narrower than it sounds.
-- Of 59 people with a preference row, 42 are unsubscribed and every one of
-- those rows carries an `unsubscribed_at` and a prompt that was actually shown
-- — they were asked and declined, and they are excluded. The 27 with no row
-- were never asked at all, and an opt-in list reads that silence as a refusal
-- nobody made. Reaching them is the legitimate-interest basis for telling an
-- account holder that the product they signed up for has changed, and both
-- letters carry a working unsubscribe link to `PREFERENCE_URL`.
--
-- `trial_reactivations` records who the reset moved, because after it ran the
-- two audiences look identical: a revived trial and a trial that was live all
-- along are both `trialing`. The membership is reconstructed from
-- `current_period_start` because that is the only trace the reset left, and it
-- is exact — nothing else wrote that column inside the window.
--
-- The cooldown fix is here rather than in its own migration because without it
-- this campaign silently loses a quarter of its audience: eleven of the
-- thirty-nine reactivated accounts received some other optional email in the
-- last fourteen days. `optional_email_cooldown_clear` was matching campaign key
-- prefixes and hardcoding two intervals while `email_campaigns.cooldown` and
-- `.founder_cooldown` sat unread on every row. It now reads them. This is
-- behaviour-preserving for every existing campaign: `trial-learning-*` rows
-- carry 72 hours, the rest carry 14 days, research carries 30 — exactly the
-- values the function had hardcoded.

create table if not exists public.trial_reactivations (
    user_id        uuid primary key references auth.users(id) on delete cascade,
    reactivated_at timestamptz not null default now()
);

alter table public.trial_reactivations enable row level security;
revoke all on table public.trial_reactivations from public, anon, authenticated;

insert into public.trial_reactivations (user_id, reactivated_at)
select s.user_id, s.current_period_start
  from public.subscriptions s
 where s.plan = 'trial'
   and s.status = 'trialing'
   and s.paddle_subscription_id is null
   and s.current_period_start between timestamptz '2026-09-09 22:46:00+00'
                                  and timestamptz '2026-09-09 22:47:00+00'
on conflict (user_id) do nothing;

insert into public.email_campaigns (
    campaign_key, version, email_class, priority, required_topics,
    template_aliases, cooldown, founder_cooldown, rollout_gate, rollout_mode,
    is_enabled, accepted_policy_versions
) values
    ('winback-release-reactivation', 1, 'marketing', 130, '{}',
     '{"en":{"default":"winback-release-reactivation-v1-en"}}'::jsonb,
     interval '1 day', null, 'marketing', 'off', false,
     array['communications-v1', 'communications-v2']),
    ('release-update-active', 1, 'marketing', 131, '{}',
     '{"en":{"default":"release-update-active-v1-en"}}'::jsonb,
     interval '1 day', null, 'marketing', 'off', false,
     array['communications-v1', 'communications-v2'])
on conflict (campaign_key, version) do nothing;

create or replace function public.optional_email_cooldown_clear(
    p_user_id uuid,
    p_email_class text,
    p_campaign_key text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    with incoming as (
        select cooldown, founder_cooldown
          from public.email_campaigns
         where campaign_key = p_campaign_key
         order by version desc
         limit 1
    )
    select not exists (
        select 1 from public.email_outbox outbox
          join public.email_campaigns campaign
            on campaign.campaign_key = outbox.campaign_key
           and campaign.version = outbox.campaign_version
         where outbox.user_id = p_user_id
           and campaign.email_class <> 'transactional'
           and outbox.status in ('queued', 'sending', 'accepted', 'delivery_unknown')
           and coalesce(outbox.accepted_at, outbox.request_started_at, outbox.created_at)
               > now() - coalesce((select cooldown from incoming), interval '14 days')
    ) and (
        p_email_class <> 'research' or not exists (
            select 1 from public.email_outbox outbox
            join public.email_campaigns campaign
              on campaign.campaign_key = outbox.campaign_key and campaign.version = outbox.campaign_version
             where outbox.user_id = p_user_id and campaign.email_class = 'research'
               and outbox.status in ('queued', 'sending', 'accepted', 'delivery_unknown')
               and coalesce(outbox.accepted_at, outbox.request_started_at, outbox.created_at)
                   > now() - coalesce((select founder_cooldown from incoming), interval '30 days')
        )
    );
$$;
revoke all on function public.optional_email_cooldown_clear(uuid, text, text) from public, anon, authenticated;
grant execute on function public.optional_email_cooldown_clear(uuid, text, text) to service_role;

create or replace function public.email_campaign_qualification(
    p_user_id uuid,
    p_campaign_key text,
    p_campaign_version integer
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_campaign public.email_campaigns%rowtype;
    v_snapshot record;
    v_program_not_before timestamptz;
    v_topic text;
    v_variant text := 'default';
    v_reason text;
    v_qualified_at timestamptz;
    v_canceled_at timestamptz;
    v_template_alias text;
begin
    select * into v_campaign from public.email_campaigns
     where campaign_key = p_campaign_key and version = p_campaign_version and is_enabled;
    if not found or v_campaign.email_class = 'transactional' then
        return jsonb_build_object('eligible', false, 'reason', 'campaign_unavailable');
    end if;
    if not public.email_campaign_rollout_allows(p_campaign_key, p_campaign_version, p_user_id) then
        return jsonb_build_object('eligible', false, 'reason', 'rollout_closed');
    end if;
    select program_not_before into v_program_not_before from public.email_program_config where singleton;
    if v_program_not_before is null or now() < v_program_not_before then
        return jsonb_build_object('eligible', false, 'reason', 'program_gate_closed');
    end if;
    select * into v_snapshot
      from public.email_user_snapshots() snapshot
     where snapshot.user_id = p_user_id;
    if not found then return jsonb_build_object('eligible', false, 'reason', 'user_unavailable'); end if;
    if exists (
        select 1 from public.email_suppressions
         where email = v_snapshot.email and scope in ('marketing', 'all_email')
    ) then return jsonb_build_object('eligible', false, 'reason', 'suppressed'); end if;

    foreach v_topic in array v_campaign.required_topics loop
        if not exists (
            select 1 from public.email_preferences preference
             where preference.user_id = p_user_id and preference.topic = v_topic
               and preference.status = 'subscribed'
               and preference.policy_version = any(v_campaign.accepted_policy_versions)
        ) then return jsonb_build_object('eligible', false, 'reason', 'missing_consent'); end if;
    end loop;

    if p_campaign_key = 'trial-learning-day-1'
       and v_snapshot.subscription_status = 'trialing'
       and now() >= v_snapshot.signup_at + interval '1 day'
       and now() < v_snapshot.signup_at + interval '2 days' then
        v_reason := 'trial_day_1'; v_qualified_at := v_snapshot.signup_at + interval '1 day'; v_variant := 'guidance';
    elsif p_campaign_key = 'trial-learning-day-4'
       and v_snapshot.subscription_status = 'trialing'
       and now() >= v_snapshot.signup_at + interval '4 days'
       and now() < v_snapshot.signup_at + interval '5 days' then
        v_reason := 'trial_day_4'; v_qualified_at := v_snapshot.signup_at + interval '4 days'; v_variant := 'guidance';
    elsif p_campaign_key = 'trial-learning-day-10'
       and v_snapshot.subscription_status = 'trialing'
       and now() >= v_snapshot.signup_at + interval '10 days'
       and now() < v_snapshot.signup_at + interval '11 days' then
        v_reason := 'trial_day_10'; v_qualified_at := v_snapshot.signup_at + interval '10 days'; v_variant := 'guidance';
    elsif p_campaign_key = 'activation-never-recorded' and v_snapshot.is_never_recorded then
        v_reason := 'trial_or_paid_without_first_meeting'; v_qualified_at := v_snapshot.signup_at + interval '2 days'; v_variant := 'guidance';
    elsif p_campaign_key = 'activation-second-meeting'
       and v_snapshot.completed_meetings = 1
       and v_snapshot.last_meaningful_value_at between now() - interval '10 days' and now() - interval '1 day'
       and v_snapshot.subscription_status in ('trialing', 'active') then
        v_reason := 'one_positive_duration_meeting'; v_qualified_at := v_snapshot.last_meaningful_value_at + interval '1 day'; v_variant := 'guidance';
    -- The at-risk letter is written around the open-commitment count, so it has
    -- nothing to say when that number is zero.
    elsif p_campaign_key = 'activation-at-risk' and v_snapshot.is_at_risk
       and coalesce(v_snapshot.open_action_items, 0) > 0 then
        v_reason := 'activated_without_value_for_7_days'; v_qualified_at := v_snapshot.last_meaningful_value_at + interval '7 days'; v_variant := 'guidance';
    elsif p_campaign_key = 'activation-chat-not-tried' and v_snapshot.is_chat_not_tried
       and v_snapshot.second_completed_at <= now() - interval '2 days' then
        v_reason := 'activated_without_ask_after_2_days'; v_qualified_at := v_snapshot.second_completed_at + interval '2 days'; v_variant := 'guidance';
    elsif p_campaign_key = 'activation-action-items-not-used' and v_snapshot.is_action_items_not_used
       and v_snapshot.second_completed_at <= now() - interval '2 days' then
        v_reason := 'open_action_items_unvisited_after_2_days'; v_qualified_at := v_snapshot.second_completed_at + interval '2 days'; v_variant := 'guidance';
    elsif p_campaign_key in ('winback-expired-offer', 'winback-expired-feedback')
       and v_snapshot.converted_at is null
       and v_snapshot.trial_ends_at between now() - interval '30 days' and now() - interval '1 day'
       and coalesce(v_snapshot.subscription_status, 'none') <> 'active' then
        v_reason := 'trial_expired_without_conversion'; v_qualified_at := v_snapshot.trial_ends_at + interval '1 day';
    elsif p_campaign_key in ('winback-canceled-offer', 'winback-canceled-feedback') then
        select max(occurred_at) into v_canceled_at from public.email_lifecycle_events
         where user_id = p_user_id and event = 'subscription_canceled';
        if v_snapshot.subscription_status = 'canceled'
           and v_canceled_at between now() - interval '30 days' and now() - interval '2 days' then
            v_reason := 'subscription_canceled'; v_qualified_at := v_canceled_at + interval '2 days';
        end if;
    elsif p_campaign_key = 'referral-launch' then
        v_reason := 'product_updates_opt_in_at_program_launch'; v_qualified_at := v_program_not_before;
    -- The two release letters carry no `required_topics`, so the consent loop
    -- above does not run for them and the rule is stated here instead: everyone
    -- who has not said no. An opt-in list cannot express that — it reads silence
    -- as refusal, and most of this base was never asked. A refusal is honoured
    -- exactly as given; only the never-asked are included.
    elsif p_campaign_key = 'winback-release-reactivation' then
        if exists (
            select 1 from public.trial_reactivations reactivation
             where reactivation.user_id = p_user_id
        ) and not exists (
            select 1 from public.email_preferences preference
             where preference.user_id = p_user_id
               and preference.topic = 'product_updates'
               and preference.status = 'unsubscribed'
        ) then
            v_reason := 'trial_reactivated_for_release'; v_qualified_at := v_program_not_before;
        end if;
    -- Whoever was already paying or already had a live trial. The reactivated
    -- accounts are excluded by name rather than by status: today's reset made
    -- them `trialing` too, and they are getting the other letter.
    elsif p_campaign_key = 'release-update-active' then
        if v_snapshot.subscription_status in ('trialing', 'active')
           and not exists (
            select 1 from public.trial_reactivations reactivation
             where reactivation.user_id = p_user_id
        ) and not exists (
            select 1 from public.email_preferences preference
             where preference.user_id = p_user_id
               and preference.topic = 'product_updates'
               and preference.status = 'unsubscribed'
        ) then
            v_reason := 'release_announcement'; v_qualified_at := v_program_not_before;
        end if;
    end if;
    if v_reason is null then return jsonb_build_object('eligible', false, 'reason', 'cohort_not_current'); end if;

    v_template_alias := v_campaign.template_aliases -> 'en' ->> v_variant;
    if v_template_alias is null then return jsonb_build_object('eligible', false, 'reason', 'template_variant_missing'); end if;
    return jsonb_build_object(
        'eligible', true, 'reason', v_reason, 'qualified_at', v_qualified_at,
        'variant', v_variant, 'template_alias', v_template_alias,
        'email', v_snapshot.email, 'first_name', v_snapshot.first_name,
        -- Counts for template personalisation; the payload builder decides which
        -- of them this campaign's template actually reads.
        'session_count', coalesce(v_snapshot.completed_meetings, 0),
        'open_commitments', coalesce(v_snapshot.open_action_items, 0),
        'days_left', case
            when v_snapshot.trial_ends_at is null or v_snapshot.trial_ends_at <= now() then null
            else ceil(extract(epoch from (v_snapshot.trial_ends_at - now())) / 86400)::integer
        end
    );
end;
$$;
revoke all on function public.email_campaign_qualification(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.email_campaign_qualification(uuid, text, integer) to service_role;
