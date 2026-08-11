-- Cohort signals in one place. Activation is defined here, in SQL, so a
-- campaign, the founder dashboard and a test all read the same definition
-- instead of three drifting copies.
--
-- "Meaningful value" is deliberately not "recorded a meeting": it is evidence
-- the person came back for the output — read a summary or transcript, worked an
-- action item, asked a question, exported something.
create or replace function public.email_user_snapshots()
returns table (
    user_id uuid,
    email text,
    first_name text,
    signup_at timestamptz,
    plan text,
    billing_cycle text,
    subscription_status text,
    converted_at timestamptz,
    trial_ends_at timestamptz,
    completed_meetings integer,
    second_completed_at timestamptz,
    last_meaningful_value_at timestamptz,
    has_user_chat boolean,
    open_action_items integer,
    has_viewed_action_items boolean,
    is_activated boolean,
    is_never_recorded boolean,
    is_at_risk boolean,
    is_chat_not_tried boolean,
    is_action_items_not_used boolean
)
language sql
stable
security definer
set search_path = ''
as $$
    with account as (
        select
            u.id as user_id,
            lower(trim(u.email)) as email,
            u.created_at as signup_at,
            coalesce(
                nullif(split_part(coalesce(p.display_name, ''), ' ', 1), ''),
                nullif(split_part(coalesce(u.email, ''), '@', 1), '')
            ) as first_name
          from auth.users u
          left join public.profiles p on p.user_id = u.id
         where coalesce(u.email, '') <> ''
    ),
    meeting_stats as (
        select
            m.user_id,
            count(*)::integer as completed_meetings,
            (array_agg(m.ended_at order by m.ended_at))[2] as second_completed_at
          from public.meetings m
         where m.deleted_at is null
           and m.ended_at is not null
         group by m.user_id
    ),
    value_signal as (
        select signal.user_id, max(signal.occurred_at) as last_meaningful_value_at
          from (
              select e.user_id, e.occurred_at
                from public.product_events e
               where e.event in (
                   'summary_viewed', 'transcript_viewed', 'action_items_viewed',
                   'content_copied', 'meeting_exported', 'ai_action_completed'
               )
              union all
              select c.user_id, c.created_at
                from public.chat_messages c
               where c.role = 'user'
              union all
              select a.user_id, a.done_at
                from public.action_items a
               where a.done_at is not null
          ) signal
         group by signal.user_id
    ),
    chat_signal as (
        select c.user_id, true as has_user_chat
          from public.chat_messages c
         where c.role = 'user'
         group by c.user_id
    ),
    action_item_signal as (
        select a.user_id, count(*) filter (where not a.done)::integer as open_action_items
          from public.action_items a
         where a.deleted_at is null
         group by a.user_id
    ),
    action_item_views as (
        select e.user_id, true as has_viewed_action_items
          from public.product_events e
         where e.event = 'action_items_viewed'
         group by e.user_id
    ),
    assembled as (
        select
            account.user_id,
            account.email,
            account.first_name,
            account.signup_at,
            subscription.plan,
            price.billing_cycle,
            subscription.status as subscription_status,
            subscription.converted_at,
            subscription.trial_ends_at,
            coalesce(meeting_stats.completed_meetings, 0) as completed_meetings,
            meeting_stats.second_completed_at,
            value_signal.last_meaningful_value_at,
            coalesce(chat_signal.has_user_chat, false) as has_user_chat,
            coalesce(action_item_signal.open_action_items, 0) as open_action_items,
            coalesce(action_item_views.has_viewed_action_items, false) as has_viewed_action_items
          from account
          left join public.subscriptions subscription on subscription.user_id = account.user_id
          left join public.plan_prices price on price.paddle_price_id = subscription.paddle_price_id
          left join meeting_stats on meeting_stats.user_id = account.user_id
          left join value_signal on value_signal.user_id = account.user_id
          left join chat_signal on chat_signal.user_id = account.user_id
          left join action_item_signal on action_item_signal.user_id = account.user_id
          left join action_item_views on action_item_views.user_id = account.user_id
    )
    select
        assembled.*,
        assembled.completed_meetings >= 2 as is_activated,
        assembled.completed_meetings = 0
            and assembled.signup_at <= now() - interval '3 days' as is_never_recorded,
        assembled.completed_meetings >= 2
            and coalesce(assembled.last_meaningful_value_at, assembled.signup_at)
                <= now() - interval '7 days' as is_at_risk,
        assembled.completed_meetings >= 2
            and not assembled.has_user_chat as is_chat_not_tried,
        assembled.completed_meetings >= 2
            and assembled.open_action_items > 0
            and not assembled.has_viewed_action_items as is_action_items_not_used
      from assembled;
$$;

-- Every optional send is decided here, and decided again at send time. Order
-- matters: program gate, then suppression, then consent at the current policy
-- version, then the cohort, then the template variant.
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
    v_policy_version text;
    v_program_not_before timestamptz;
    v_topic text;
    v_variant text := 'default';
    v_reason text;
    v_qualified_at timestamptz;
    v_yearly_at timestamptz;
    v_canceled_at timestamptz;
    v_template_alias text;
begin
    select * into v_campaign
      from public.email_campaigns
     where campaign_key = p_campaign_key
       and version = p_campaign_version
       and is_enabled;
    if not found or v_campaign.email_class = 'transactional' then
        return jsonb_build_object('eligible', false, 'reason', 'campaign_unavailable');
    end if;

    select policy_version, program_not_before
      into v_policy_version, v_program_not_before
      from public.email_program_config
     where singleton;
    if v_program_not_before is null or now() < v_program_not_before then
        return jsonb_build_object('eligible', false, 'reason', 'program_gate_closed');
    end if;

    select * into v_snapshot
      from public.email_user_snapshots() snapshot
     where snapshot.user_id = p_user_id;
    if not found then
        return jsonb_build_object('eligible', false, 'reason', 'user_unavailable');
    end if;

    if exists (
        select 1 from public.email_suppressions suppression
         where suppression.email = v_snapshot.email
           and suppression.scope in ('marketing', 'all_email')
    ) then
        return jsonb_build_object('eligible', false, 'reason', 'suppressed');
    end if;

    foreach v_topic in array v_campaign.required_topics loop
        if not exists (
            select 1 from public.email_preferences preference
             where preference.user_id = p_user_id
               and preference.topic = v_topic
               and preference.status = 'subscribed'
               and preference.policy_version = v_policy_version
        ) then
            return jsonb_build_object('eligible', false, 'reason', 'missing_consent');
        end if;
    end loop;

    if p_campaign_key = 'activation-never-recorded' and v_snapshot.is_never_recorded then
        v_reason := 'signed_up_3_days_ago_without_a_completed_meeting';
        v_qualified_at := v_snapshot.signup_at + interval '3 days';
    elsif p_campaign_key = 'activation-at-risk' and v_snapshot.is_at_risk then
        v_reason := 'two_or_more_meetings_without_meaningful_value_for_7_days';
        v_qualified_at := coalesce(v_snapshot.last_meaningful_value_at, v_snapshot.signup_at) + interval '7 days';
    elsif p_campaign_key = 'activation-chat-not-tried' and v_snapshot.is_chat_not_tried then
        v_reason := 'activated_without_asking_a_question';
        v_qualified_at := v_snapshot.second_completed_at;
    elsif p_campaign_key = 'activation-action-items-not-used' and v_snapshot.is_action_items_not_used then
        v_reason := 'open_action_items_never_opened';
        v_qualified_at := v_snapshot.second_completed_at;
    elsif p_campaign_key = 'founder-trial'
       and v_snapshot.subscription_status = 'trialing'
       and v_snapshot.trial_ends_at > now()
       and v_snapshot.signup_at between now() - interval '10 days' and now() - interval '7 days'
       and v_snapshot.is_activated
       and not v_snapshot.is_at_risk then
        v_reason := 'activated_trial_day_7_to_10';
        v_qualified_at := v_snapshot.signup_at + interval '7 days';
    elsif p_campaign_key = 'founder-active'
       and v_snapshot.subscription_status = 'active'
       and v_snapshot.billing_cycle = 'monthly'
       and v_snapshot.converted_at between now() - interval '30 days' and now() - interval '7 days' then
        v_reason := 'monthly_paid_conversion_7_to_30_days_ago';
        v_qualified_at := v_snapshot.converted_at + interval '7 days';
    elsif p_campaign_key = 'founder-annual' then
        select min(event.occurred_at) into v_yearly_at
          from public.email_lifecycle_events event
         where event.user_id = p_user_id and event.event = 'yearly_entered';
        if v_snapshot.subscription_status = 'active'
           and v_snapshot.billing_cycle = 'yearly'
           and v_yearly_at between now() - interval '30 days' and now() - interval '7 days' then
            v_reason := 'first_yearly_plan_entry_7_to_30_days_ago';
            v_qualified_at := v_yearly_at + interval '7 days';
        end if;
    elsif p_campaign_key = 'founder-expired'
       and v_snapshot.converted_at is null
       and v_snapshot.trial_ends_at between now() - interval '30 days' and now() - interval '1 day'
       and coalesce(v_snapshot.subscription_status, 'none') <> 'active' then
        v_reason := 'trial_expired_1_to_30_days_ago_without_conversion';
        v_qualified_at := v_snapshot.trial_ends_at + interval '1 day';
    elsif p_campaign_key = 'founder-canceled' then
        select max(event.occurred_at) into v_canceled_at
          from public.email_lifecycle_events event
         where event.user_id = p_user_id and event.event = 'subscription_canceled';
        if v_snapshot.subscription_status = 'canceled'
           and v_canceled_at between now() - interval '30 days' and now() - interval '2 days' then
            v_reason := 'subscription_canceled_2_to_30_days_ago';
            v_qualified_at := v_canceled_at + interval '2 days';
        end if;
    elsif p_campaign_key = 'referral-launch' then
        v_reason := 'product_updates_opt_in_at_program_launch';
        v_qualified_at := v_program_not_before;
    end if;

    if v_reason is null then
        return jsonb_build_object('eligible', false, 'reason', 'cohort_not_current');
    end if;

    -- An activation nudge reads better from a person when that person is
    -- already someone the reader agreed to hear from.
    if p_campaign_key like 'activation-%' then
        if exists (
            select 1 from public.email_preferences preference
             where preference.user_id = p_user_id
               and preference.topic = 'founder_research'
               and preference.status = 'subscribed'
               and preference.policy_version = v_policy_version
        ) then
            v_variant := 'founder';
        else
            v_variant := 'guidance';
        end if;
    end if;

    v_template_alias := v_campaign.template_aliases -> 'en' ->> v_variant;
    if v_template_alias is null then
        return jsonb_build_object('eligible', false, 'reason', 'template_variant_missing');
    end if;

    return jsonb_build_object(
        'eligible', true,
        'reason', v_reason,
        'qualified_at', v_qualified_at,
        'variant', v_variant,
        'template_alias', v_template_alias,
        'email', v_snapshot.email,
        'first_name', v_snapshot.first_name
    );
end;
$$;

-- One optional email per 14 days, and a founder-voice email at most every 30.
-- Counted from what we queued or accepted, never from what was delivered, so a
-- provider outage cannot turn into a burst.
create or replace function public.optional_email_cooldown_clear(
    p_user_id uuid,
    p_email_class text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select not exists (
        select 1
          from public.email_outbox outbox
          join public.email_campaigns campaign
            on campaign.campaign_key = outbox.campaign_key
           and campaign.version = outbox.campaign_version
         where outbox.user_id = p_user_id
           and campaign.email_class <> 'transactional'
           and outbox.status in ('queued', 'sending', 'accepted', 'delivery_unknown')
           and coalesce(outbox.accepted_at, outbox.request_started_at, outbox.created_at)
               > now() - interval '14 days'
    ) and (
        p_email_class <> 'research'
        or not exists (
            select 1
              from public.email_outbox outbox
              join public.email_campaigns campaign
                on campaign.campaign_key = outbox.campaign_key
               and campaign.version = outbox.campaign_version
             where outbox.user_id = p_user_id
               and (campaign.email_class = 'research' or outbox.consent_variant = 'founder')
               and outbox.status in ('queued', 'sending', 'accepted', 'delivery_unknown')
               and coalesce(outbox.accepted_at, outbox.request_started_at, outbox.created_at)
                   > now() - interval '30 days'
        )
    );
$$;

create or replace function public.enqueue_optional_email(
    p_user_id uuid,
    p_campaign_key text,
    p_campaign_version integer default 1
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_campaign public.email_campaigns%rowtype;
    v_qualification jsonb;
    v_claim_id uuid;
    v_outbox_id uuid;
    v_token text;
    v_first_name text;
begin
    -- Serialised per person: two campaigns qualifying in the same tick must not
    -- both slip past the cadence check.
    perform pg_advisory_xact_lock(hashtext('email-user:' || p_user_id::text));

    select * into v_campaign
      from public.email_campaigns
     where campaign_key = p_campaign_key
       and version = p_campaign_version
       and email_class <> 'transactional';
    if not found then
        return null;
    end if;

    v_qualification := public.email_campaign_qualification(p_user_id, p_campaign_key, p_campaign_version);
    if not coalesce((v_qualification ->> 'eligible')::boolean, false) then
        return null;
    end if;
    if not public.optional_email_cooldown_clear(
        p_user_id,
        case when v_qualification ->> 'variant' = 'founder' then 'research' else v_campaign.email_class end
    ) then
        return null;
    end if;

    insert into public.email_send_claims (
        user_id, campaign_key, campaign_version, business_key, idempotency_key
    ) values (
        p_user_id, p_campaign_key, p_campaign_version,
        'user:' || p_user_id::text,
        p_campaign_key || '-v' || p_campaign_version::text || '-user-' || p_user_id::text
    )
    on conflict do nothing
    returning id into v_claim_id;
    if v_claim_id is null then
        return null;
    end if;

    v_token := public.issue_email_preference_token(p_user_id);
    v_first_name := coalesce(nullif(v_qualification ->> 'first_name', ''), 'there');

    insert into public.email_outbox (
        claim_id, user_id, email, campaign_key, campaign_version,
        template_alias, consent_variant, qualification_reason, qualified_at, payload
    ) values (
        v_claim_id, p_user_id, lower(trim(v_qualification ->> 'email')),
        p_campaign_key, p_campaign_version,
        v_qualification ->> 'template_alias',
        v_qualification ->> 'variant',
        v_qualification ->> 'reason',
        (v_qualification ->> 'qualified_at')::timestamptz,
        jsonb_build_object(
            'FIRST_NAME', v_first_name,
            'first_name', v_first_name,
            'APP_URL', 'https://hellonod.app',
            'DOWNLOAD_URL', 'https://hellonod.app',
            'CALENDLY_URL', 'https://calendly.com/meet-vlad-from-nod/30min',
            'calendly_url', 'https://calendly.com/meet-vlad-from-nod/30min',
            'PREFERENCE_URL', 'https://hellonod.app/email-preferences#' || coalesce(v_token, '')
        )
    ) returning id into v_outbox_id;
    return v_outbox_id;
end;
$$;

-- Transactional notices carry no consent requirement and no cadence, but they
-- are still queued behind the program gate and still deduplicated per entity.
create or replace function public.enqueue_transactional_email(
    p_user_id uuid,
    p_campaign_key text,
    p_business_key text,
    p_payload jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_campaign public.email_campaigns%rowtype;
    v_email text;
    v_claim_id uuid;
    v_outbox_id uuid;
    v_status text := 'queued';
begin
    select * into v_campaign
      from public.email_campaigns
     where campaign_key = p_campaign_key
       and version = 1
       and email_class = 'transactional'
       and is_enabled;
    if not found then
        return null;
    end if;

    select lower(trim(email)) into v_email from auth.users where id = p_user_id;
    if coalesce(v_email, '') = '' then
        return null;
    end if;
    if exists (
        select 1 from public.email_suppressions
         where email = v_email and scope = 'all_email'
    ) then
        v_status := 'suppressed';
    end if;

    insert into public.email_send_claims (
        user_id, campaign_key, campaign_version, business_key, idempotency_key
    ) values (
        p_user_id, p_campaign_key, 1, p_business_key,
        p_campaign_key || '-v1-' || p_business_key
    )
    on conflict do nothing
    returning id into v_claim_id;
    if v_claim_id is null then
        return null;
    end if;

    insert into public.email_outbox (
        claim_id, user_id, email, campaign_key, campaign_version,
        template_alias, consent_variant, qualification_reason, qualified_at, payload, status
    ) values (
        v_claim_id, p_user_id, v_email, p_campaign_key, 1,
        v_campaign.template_aliases -> 'en' ->> 'transactional',
        'transactional',
        p_campaign_key || ':' || p_business_key,
        now(),
        coalesce(p_payload, '{}'::jsonb),
        v_status
    ) returning id into v_outbox_id;
    return v_outbox_id;
end;
$$;

create or replace function public.scan_email_candidates()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user record;
    v_campaign record;
    v_outbox_id uuid;
    v_optional integer := 0;
    v_transactional integer := 0;
    v_excluded uuid[] := public._excluded_user_ids();
    v_credit record;
begin
    -- Reward-earned notices are entity-driven, so they are safe to scan for
    -- even while the optional program is gated shut.
    for v_credit in
        select credit.id, credit.beneficiary_user_id, credit.expires_at
          from public.reward_credits credit
         where credit.source_type = 'referral'
           and credit.status in ('pending', 'payout_pending', 'applied')
           and credit.available_at <= now()
           and credit.expires_at > now()
           and not exists (
               select 1 from public.email_send_claims claim
                where claim.campaign_key = 'referral-reward-earned'
                  and claim.campaign_version = 1
                  and claim.user_id = credit.beneficiary_user_id
                  and claim.business_key = 'reward-credit:' || credit.id::text
           )
         order by credit.available_at, credit.id
         limit 200
    loop
        v_outbox_id := public.enqueue_transactional_email(
            v_credit.beneficiary_user_id,
            'referral-reward-earned',
            'reward-credit:' || v_credit.id::text,
            jsonb_build_object(
                'REWARD_LABEL', 'a free month of Nod',
                'EXPIRES_AT', v_credit.expires_at::date::text
            )
        );
        if v_outbox_id is not null then
            v_transactional := v_transactional + 1;
        end if;
    end loop;

    if not public.email_program_gate_open() then
        return jsonb_build_object(
            'optional_enqueued', 0,
            'transactional_enqueued', v_transactional,
            'skipped', 'program_gate_closed'
        );
    end if;

    -- One campaign per person per pass, highest priority first.
    for v_user in
        select snapshot.user_id
          from public.email_user_snapshots() snapshot
         where snapshot.user_id <> all(v_excluded)
         order by snapshot.signup_at
    loop
        for v_campaign in
            select campaign.campaign_key, campaign.version
              from public.email_campaigns campaign
             where campaign.email_class <> 'transactional'
               and campaign.is_enabled
               and not exists (
                   select 1 from public.email_send_claims claim
                    where claim.user_id = v_user.user_id
                      and claim.campaign_key = campaign.campaign_key
                      and claim.campaign_version = campaign.version
               )
             order by campaign.priority
        loop
            v_outbox_id := public.enqueue_optional_email(
                v_user.user_id, v_campaign.campaign_key, v_campaign.version
            );
            if v_outbox_id is not null then
                v_optional := v_optional + 1;
                exit;
            end if;
        end loop;
    end loop;

    return jsonb_build_object(
        'optional_enqueued', v_optional,
        'transactional_enqueued', v_transactional
    );
end;
$$;

create or replace function public.queue_referral_friend_subscribed_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if new.status = 'activated' and old.status is distinct from 'activated' then
        perform public.enqueue_transactional_email(
            new.referrer_user_id,
            'referral-friend-subscribed',
            'referral:' || new.id::text,
            '{}'::jsonb
        );
    end if;
    return new;
end;
$$;

drop trigger if exists queue_referral_friend_subscribed_email on public.referrals;
create trigger queue_referral_friend_subscribed_email
    after update of status on public.referrals
    for each row execute function public.queue_referral_friend_subscribed_email();

create or replace function public.queue_referral_reward_applied_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if new.status = 'applied' and old.status is distinct from 'applied' then
        perform public.enqueue_transactional_email(
            new.beneficiary_user_id,
            'referral-reward-applied',
            'payout:' || new.id::text,
            jsonb_build_object('NEXT_BILLING_DATE', new.target_next_billed_at::date::text)
        );
    end if;
    return new;
end;
$$;

drop trigger if exists queue_referral_reward_applied_email on public.reward_payouts;
create trigger queue_referral_reward_applied_email
    after update of status on public.reward_payouts
    for each row execute function public.queue_referral_reward_applied_email();

-- Claiming also repairs: rows a crashed worker left mid-flight are either
-- retried (no provider call was made) or parked as delivery_unknown (one may
-- have been), never blindly resent.
create or replace function public.claim_email_outbox(p_limit integer default 20)
returns setof public.email_outbox
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.email_outbox
       set status = 'queued',
           last_error = coalesce(last_error, 'worker_lease_expired_before_provider_request'),
           available_at = now(),
           updated_at = now()
     where status = 'sending'
       and request_started_at is null
       and updated_at < now() - interval '10 minutes';

    update public.email_outbox
       set status = 'delivery_unknown',
           last_error = coalesce(last_error, 'worker_lease_expired_after_possible_provider_request'),
           updated_at = now()
     where status = 'sending'
       and request_started_at is not null
       and request_started_at < now() - interval '10 minutes';

    update public.email_outbox
       set status = 'canceled',
           last_error = coalesce(last_error, 'queued_past_expiry'),
           updated_at = now()
     where status = 'queued'
       and expires_at <= now();

    if not public.email_program_gate_open() then
        return;
    end if;

    return query
    with selected as (
        select id
          from public.email_outbox outbox
         where outbox.status = 'queued'
           and outbox.available_at <= now()
           and outbox.expires_at > now()
         order by outbox.available_at, outbox.created_at
         limit greatest(1, least(coalesce(p_limit, 20), 100))
         for update skip locked
    )
    update public.email_outbox outbox
       set status = 'sending',
           attempts = outbox.attempts + 1,
           request_started_at = null,
           updated_at = now()
      from selected
     where outbox.id = selected.id
    returning outbox.*;
end;
$$;

-- The last check before the provider is called. Consent, suppression, the gate
-- and the underlying entity are all re-read here, because minutes may have
-- passed since the row was queued.
create or replace function public.email_outbox_send_guard(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_outbox public.email_outbox%rowtype;
    v_campaign public.email_campaigns%rowtype;
    v_qualification jsonb;
    v_business_key text;
    v_entity_id uuid;
begin
    select * into v_outbox from public.email_outbox where id = p_id;
    if not found or v_outbox.status <> 'sending' then
        return false;
    end if;
    if not public.email_program_gate_open() then
        return false;
    end if;
    select * into v_campaign
      from public.email_campaigns
     where campaign_key = v_outbox.campaign_key
       and version = v_outbox.campaign_version
       and is_enabled;
    if not found then
        return false;
    end if;
    if exists (
        select 1 from public.email_suppressions suppression
         where suppression.email = v_outbox.email
           and (
               suppression.scope = 'all_email'
               or (suppression.scope = 'marketing' and v_campaign.email_class <> 'transactional')
           )
    ) then
        return false;
    end if;

    if v_campaign.email_class <> 'transactional' then
        v_qualification := public.email_campaign_qualification(
            v_outbox.user_id, v_outbox.campaign_key, v_outbox.campaign_version
        );
        if not coalesce((v_qualification ->> 'eligible')::boolean, false) then
            return false;
        end if;
        -- Consent may have changed the right voice since queueing; lock in what
        -- is consented right now.
        update public.email_outbox
           set consent_variant = v_qualification ->> 'variant',
               template_alias = v_qualification ->> 'template_alias',
               updated_at = now()
         where id = p_id and status = 'sending';
        return true;
    end if;

    select claim.business_key into v_business_key
      from public.email_send_claims claim
     where claim.id = v_outbox.claim_id;
    begin
        v_entity_id := split_part(v_business_key, ':', 2)::uuid;
    exception when others then
        return false;
    end;

    if v_outbox.campaign_key = 'referral-friend-subscribed' then
        return exists (
            select 1 from public.referrals referral
             where referral.id = v_entity_id
               and referral.referrer_user_id = v_outbox.user_id
               and referral.status in ('activated', 'earned', 'rewarded')
        );
    elsif v_outbox.campaign_key = 'referral-reward-earned' then
        return exists (
            select 1 from public.reward_credits credit
             where credit.id = v_entity_id
               and credit.beneficiary_user_id = v_outbox.user_id
               and credit.source_type = 'referral'
               and credit.status in ('pending', 'payout_pending', 'applied')
               and credit.available_at <= now()
               and credit.expires_at > now()
        );
    elsif v_outbox.campaign_key = 'referral-reward-applied' then
        return exists (
            select 1 from public.reward_payouts payout
             where payout.id = v_entity_id
               and payout.beneficiary_user_id = v_outbox.user_id
               and payout.status = 'applied'
        );
    end if;
    return false;
end;
$$;

create or replace function public.email_outbox_delivery_payload(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
    select jsonb_build_object(
        'email', outbox.email,
        'template_alias', outbox.template_alias,
        'payload', outbox.payload
    )
      from public.email_outbox outbox
     where outbox.id = p_id and outbox.status = 'sending';
$$;

-- Marks the exact instant a provider call may have been made. Anything after
-- this point can only be resolved, never retried blindly.
create or replace function public.begin_email_provider_request(
    p_id uuid,
    p_expected_template_alias text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_started boolean;
begin
    update public.email_outbox
       set request_started_at = now(),
           updated_at = now()
     where id = p_id
       and status = 'sending'
       and request_started_at is null
       and template_alias = p_expected_template_alias
    returning true into v_started;
    return coalesce(v_started, false);
end;
$$;

create or replace function public.defer_email_outbox(p_id uuid, p_error text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.email_outbox
       set status = 'queued',
           available_at = now() + (interval '5 minutes' * greatest(attempts, 1)),
           request_started_at = null,
           last_error = p_error,
           updated_at = now()
     where id = p_id
       and status = 'sending';
end;
$$;

create or replace function public.complete_email_outbox(
    p_id uuid,
    p_outcome text,
    p_provider_email_id text,
    p_error text,
    p_retryable boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_outbox public.email_outbox%rowtype;
begin
    select * into v_outbox from public.email_outbox where id = p_id for update;
    if not found then
        return;
    end if;

    if p_outcome = 'accepted' then
        update public.email_outbox
           set status = 'accepted',
               provider_email_id = p_provider_email_id,
               provider_status = coalesce(provider_status, 'accepted'),
               provider_status_at = coalesce(provider_status_at, now()),
               accepted_at = coalesce(accepted_at, now()),
               last_error = null,
               updated_at = now()
         where id = p_id;
        -- A delivery or complaint webhook can beat our own response; fold in
        -- whatever already landed for this provider id.
        if p_provider_email_id is not null then
            perform public.reconcile_email_delivery_events(p_provider_email_id);
        end if;
        return;
    end if;

    if p_outcome = 'delivery_unknown' then
        update public.email_outbox
           set status = 'delivery_unknown',
               last_error = p_error,
               updated_at = now()
         where id = p_id;
        return;
    end if;

    if p_outcome = 'rejected' and coalesce(p_retryable, false) and v_outbox.attempts < 6 then
        update public.email_outbox
           set status = 'queued',
               available_at = now() + (interval '10 minutes' * v_outbox.attempts),
               request_started_at = null,
               last_error = p_error,
               updated_at = now()
         where id = p_id;
        return;
    end if;

    update public.email_outbox
       set status = case when p_outcome = 'canceled' then 'canceled' else 'failed' end,
           provider_status = case when p_outcome = 'canceled' then provider_status else 'failed' end,
           last_error = p_error,
           updated_at = now()
     where id = p_id;
end;
$$;

create or replace function public.reconcile_email_delivery_events(p_provider_email_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_event record;
begin
    for v_event in
        select event_type, coalesce(occurred_at, received_at) as occurred_at, email
          from public.email_webhook_events
         where provider_email_id = p_provider_email_id
         order by coalesce(occurred_at, received_at)
    loop
        perform public.apply_email_delivery_event(
            p_provider_email_id, v_event.event_type, v_event.occurred_at, v_event.email, null
        );
    end loop;
end;
$$;

-- Terminal states win regardless of arrival order: a complaint must never be
-- overwritten by a delivery that was emitted earlier but arrived later.
create or replace function public.apply_email_delivery_event(
    p_provider_email_id text,
    p_event_type text,
    p_occurred_at timestamptz,
    p_email text,
    p_provider_event_id text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_email text := nullif(lower(trim(p_email)), '');
    v_at timestamptz := coalesce(p_occurred_at, now());
begin
    if p_event_type = 'email.delivered' then
        update public.email_outbox
           set provider_status = 'delivered',
               provider_status_at = v_at,
               delivered_at = v_at,
               updated_at = now()
         where provider_email_id = p_provider_email_id
           and coalesce(provider_status, 'accepted') not in ('bounced', 'complained', 'suppressed')
           and (provider_status_at is null or provider_status_at <= v_at);
    elsif p_event_type = 'email.failed' then
        update public.email_outbox
           set provider_status = 'failed',
               provider_status_at = v_at,
               last_error = coalesce(last_error, 'provider_delivery_failed'),
               updated_at = now()
         where provider_email_id = p_provider_email_id
           and coalesce(provider_status, 'accepted') not in ('bounced', 'complained', 'suppressed')
           and (provider_status_at is null or provider_status_at <= v_at);
    elsif p_event_type in ('email.bounced', 'email.complained', 'email.suppressed') then
        update public.email_outbox
           set provider_status = case p_event_type
                   when 'email.bounced' then 'bounced'
                   when 'email.complained' then 'complained'
                   else 'suppressed'
               end,
               provider_status_at = v_at,
               updated_at = now()
         where provider_email_id = p_provider_email_id
           and (provider_status_at is null or provider_status_at <= v_at);

        if v_email is not null then
            insert into public.email_suppressions as suppression (
                email, scope, reason, source, provider_event_id, suppressed_at, updated_at
            ) values (
                v_email, 'all_email',
                case p_event_type
                    when 'email.bounced' then 'bounce'
                    when 'email.complained' then 'complaint'
                    else 'provider_suppression'
                end,
                'resend_webhook', p_provider_event_id, v_at, now()
            )
            on conflict (email, scope) do update set
                reason = excluded.reason,
                source = excluded.source,
                provider_event_id = coalesce(excluded.provider_event_id, suppression.provider_event_id),
                suppressed_at = least(suppression.suppressed_at, excluded.suppressed_at),
                updated_at = now();

            update public.email_outbox
               set status = 'canceled',
                   last_error = 'recipient_suppressed',
                   updated_at = now()
             where email = v_email and status in ('queued', 'sending');
        end if;
    end if;
end;
$$;

create or replace function public.record_email_webhook(
    p_provider_event_id text,
    p_event_type text,
    p_provider_email_id text,
    p_email text,
    p_payload jsonb,
    p_occurred_at timestamptz default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_inserted integer;
begin
    insert into public.email_webhook_events (
        provider_event_id, event_type, provider_email_id, email,
        payload, occurred_at, processed_at
    ) values (
        p_provider_event_id, p_event_type, p_provider_email_id,
        nullif(lower(trim(p_email)), ''), coalesce(p_payload, '{}'::jsonb), p_occurred_at,
        case when p_event_type = 'contact.updated' then null else now() end
    )
    on conflict (provider_event_id) do nothing;
    get diagnostics v_inserted = row_count;
    if v_inserted <> 1 then
        return false;
    end if;

    perform public.apply_email_delivery_event(
        p_provider_email_id, p_event_type, coalesce(p_occurred_at, now()),
        p_email, p_provider_event_id
    );
    return true;
end;
$$;

create or replace function public.complete_email_webhook_event(p_provider_event_id text)
returns void
language sql
security definer
set search_path = ''
as $$
    update public.email_webhook_events
       set processed_at = now()
     where provider_event_id = p_provider_event_id;
$$;

-- Provider-side opt-out mirrors into Supabase. Opt-IN never does: consent is
-- only ever created by the person, in our own surfaces.
create or replace function public.apply_resend_topic_status(
    p_email text,
    p_topic text,
    p_status text,
    p_provider_event_id text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_email text := lower(trim(p_email));
    v_user_id uuid;
    v_policy_version text;
begin
    if p_topic not in ('product_updates', 'lifecycle_guidance', 'founder_research')
       or p_status <> 'unsubscribed' then
        return false;
    end if;
    select id into v_user_id from auth.users where lower(trim(email)) = v_email;
    if v_user_id is null then
        return false;
    end if;
    select policy_version into v_policy_version from public.email_program_config where singleton;

    insert into public.email_preferences as current_preference (
        user_id, topic, status, policy_version, source, unsubscribed_at, updated_at
    ) values (
        v_user_id, p_topic, 'unsubscribed', v_policy_version, 'resend_webhook', now(), now()
    )
    on conflict (user_id, topic) do update set
        status = 'unsubscribed',
        source = 'resend_webhook',
        unsubscribed_at = now(),
        updated_at = now()
    where current_preference.status <> 'unsubscribed';
    return true;
end;
$$;

-- Outcome measurement without open or click tracking: accepted delivery
-- followed by real first-party activity inside 14 days.
create or replace function public.measure_email_behavioral_conversions()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_updated integer;
begin
    with eligible as (
        select outbox.id, min(activity.occurred_at) as conversion_at
          from public.email_outbox outbox
          cross join lateral (
              select meeting.ended_at as occurred_at
                from public.meetings meeting
               where meeting.user_id = outbox.user_id
                 and meeting.deleted_at is null
                 and meeting.ended_at is not null
              union all
              select message.created_at
                from public.chat_messages message
               where message.user_id = outbox.user_id
                 and message.role = 'user'
              union all
              select event.occurred_at
                from public.product_events event
               where event.user_id = outbox.user_id
                 and event.event in (
                     'summary_viewed', 'transcript_viewed', 'action_items_viewed',
                     'content_copied', 'meeting_exported', 'ai_action_completed'
                 )
          ) activity
         where outbox.status in ('accepted', 'delivery_unknown')
           and outbox.conversion_at is null
           and activity.occurred_at > coalesce(outbox.delivered_at, outbox.accepted_at)
           and activity.occurred_at <= coalesce(outbox.delivered_at, outbox.accepted_at) + interval '14 days'
         group by outbox.id
    )
    update public.email_outbox outbox
       set conversion_at = eligible.conversion_at,
           updated_at = now()
      from eligible
     where outbox.id = eligible.id;
    get diagnostics v_updated = row_count;
    return v_updated;
end;
$$;

create or replace function public.purge_expired_email_operations()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_outbox integer;
    v_webhooks integer;
    v_sync integer;
    v_tokens integer;
    v_cron integer := 0;
begin
    delete from public.email_outbox
     where created_at < now() - interval '90 days'
       and status in ('accepted', 'delivery_unknown', 'failed', 'suppressed', 'canceled');
    get diagnostics v_outbox = row_count;

    delete from public.email_webhook_events where received_at < now() - interval '90 days';
    get diagnostics v_webhooks = row_count;

    delete from public.resend_contact_sync
     where updated_at < now() - interval '90 days'
       and status in ('synced', 'failed');
    get diagnostics v_sync = row_count;

    delete from public.email_preference_tokens where expires_at < now();
    get diagnostics v_tokens = row_count;

    -- Job history grows unbounded otherwise, and a failing schedule is exactly
    -- what we need to still be able to read.
    begin
        delete from cron.job_run_details where end_time < now() - interval '7 days';
        get diagnostics v_cron = row_count;
    exception when others then
        v_cron := -1;
    end;

    return jsonb_build_object(
        'outbox', v_outbox,
        'webhooks', v_webhooks,
        'contact_sync', v_sync,
        'preference_tokens', v_tokens,
        'cron_history', v_cron
    );
end;
$$;

-- Founder read model: one row per attempted send, why it qualified, what the
-- provider did, and whether real activity followed.
create or replace function public.founder_email_outreach()
returns table (
    outreach_id uuid,
    user_id uuid,
    email text,
    campaign_key text,
    email_class text,
    qualification_reason text,
    consent_variant text,
    queue_status text,
    delivery_status text,
    qualified_at timestamptz,
    queued_at timestamptz,
    accepted_at timestamptz,
    delivered_at timestamptz,
    attempts integer,
    last_error text,
    converted_within_14d boolean,
    conversion_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    perform public._assert_founder();
    return query
    select
        outbox.id,
        outbox.user_id,
        outbox.email,
        outbox.campaign_key,
        campaign.email_class,
        outbox.qualification_reason,
        outbox.consent_variant,
        outbox.status,
        outbox.provider_status,
        outbox.qualified_at,
        outbox.created_at,
        outbox.accepted_at,
        outbox.delivered_at,
        outbox.attempts,
        outbox.last_error,
        outbox.conversion_at is not null,
        outbox.conversion_at
      from public.email_outbox outbox
      join public.email_campaigns campaign
        on campaign.campaign_key = outbox.campaign_key
       and campaign.version = outbox.campaign_version
     where outbox.user_id <> all(public._excluded_user_ids())
     order by outbox.created_at desc;
end;
$$;

revoke all on function public.email_user_snapshots() from public, anon, authenticated;
revoke all on function public.email_campaign_qualification(uuid, text, integer) from public, anon, authenticated;
revoke all on function public.optional_email_cooldown_clear(uuid, text) from public, anon, authenticated;
revoke all on function public.enqueue_optional_email(uuid, text, integer) from public, anon, authenticated;
revoke all on function public.enqueue_transactional_email(uuid, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.scan_email_candidates() from public, anon, authenticated;
revoke all on function public.queue_referral_friend_subscribed_email() from public, anon, authenticated;
revoke all on function public.queue_referral_reward_applied_email() from public, anon, authenticated;
revoke all on function public.claim_email_outbox(integer) from public, anon, authenticated;
revoke all on function public.email_outbox_send_guard(uuid) from public, anon, authenticated;
revoke all on function public.email_outbox_delivery_payload(uuid) from public, anon, authenticated;
revoke all on function public.begin_email_provider_request(uuid, text) from public, anon, authenticated;
revoke all on function public.defer_email_outbox(uuid, text) from public, anon, authenticated;
revoke all on function public.complete_email_outbox(uuid, text, text, text, boolean) from public, anon, authenticated;
revoke all on function public.reconcile_email_delivery_events(text) from public, anon, authenticated;
revoke all on function public.apply_email_delivery_event(text, text, timestamptz, text, text) from public, anon, authenticated;
revoke all on function public.record_email_webhook(text, text, text, text, jsonb, timestamptz) from public, anon, authenticated;
revoke all on function public.complete_email_webhook_event(text) from public, anon, authenticated;
revoke all on function public.apply_resend_topic_status(text, text, text, text) from public, anon, authenticated;
revoke all on function public.measure_email_behavioral_conversions() from public, anon, authenticated;
revoke all on function public.purge_expired_email_operations() from public, anon, authenticated;
revoke all on function public.founder_email_outreach() from public, anon;

grant execute on function public.email_user_snapshots() to service_role;
grant execute on function public.email_campaign_qualification(uuid, text, integer) to service_role;
grant execute on function public.optional_email_cooldown_clear(uuid, text) to service_role;
grant execute on function public.enqueue_optional_email(uuid, text, integer) to service_role;
grant execute on function public.enqueue_transactional_email(uuid, text, text, jsonb) to service_role;
grant execute on function public.scan_email_candidates() to service_role;
grant execute on function public.queue_referral_friend_subscribed_email() to service_role;
grant execute on function public.queue_referral_reward_applied_email() to service_role;
grant execute on function public.claim_email_outbox(integer) to service_role;
grant execute on function public.email_outbox_send_guard(uuid) to service_role;
grant execute on function public.email_outbox_delivery_payload(uuid) to service_role;
grant execute on function public.begin_email_provider_request(uuid, text) to service_role;
grant execute on function public.defer_email_outbox(uuid, text) to service_role;
grant execute on function public.complete_email_outbox(uuid, text, text, text, boolean) to service_role;
grant execute on function public.reconcile_email_delivery_events(text) to service_role;
grant execute on function public.apply_email_delivery_event(text, text, timestamptz, text, text) to service_role;
grant execute on function public.record_email_webhook(text, text, text, text, jsonb, timestamptz) to service_role;
grant execute on function public.complete_email_webhook_event(text) to service_role;
grant execute on function public.apply_resend_topic_status(text, text, text, text) to service_role;
grant execute on function public.measure_email_behavioral_conversions() to service_role;
grant execute on function public.purge_expired_email_operations() to service_role;
grant execute on function public.founder_email_outreach() to authenticated;
