-- Personalisation counts for the lifecycle templates.
--
-- SESSION_COUNT, OPEN_COMMITMENTS and DAYS_LEFT are counts derived from usage,
-- never meeting content, so they stay inside the "no meeting content is ever
-- shared" commitment in privacy.md § 3.14.
--
-- LAST_SESSION_TITLE is deliberately NOT populated here. A meeting title is
-- meeting content, and the published policy says Resend receives no meeting
-- content. The templates already carry the "your last call" fallback, so they
-- read correctly until that promise is renegotiated.
--
-- Each value is omitted rather than sent as zero when it would read badly, so
-- the template fallback ("a few") wins instead of "0 sessions".

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
    v_app_url text;
    v_payload jsonb;
    v_session_count integer;
    v_open_commitments integer;
    v_days_left integer;
begin
    perform pg_advisory_xact_lock(hashtext('email-user:' || p_user_id::text));
    select * into v_campaign from public.email_campaigns
     where campaign_key = p_campaign_key and version = p_campaign_version and email_class <> 'transactional';
    if not found then return null; end if;
    v_qualification := public.email_campaign_qualification(p_user_id, p_campaign_key, p_campaign_version);
    if not coalesce((v_qualification ->> 'eligible')::boolean, false) then return null; end if;
    if not public.optional_email_cooldown_clear(p_user_id, v_campaign.email_class, p_campaign_key) then return null; end if;

    insert into public.email_send_claims (user_id, campaign_key, campaign_version, business_key, idempotency_key)
    values (p_user_id, p_campaign_key, p_campaign_version, 'user:' || p_user_id::text,
            p_campaign_key || '-v' || p_campaign_version::text || '-user-' || p_user_id::text)
    on conflict do nothing returning id into v_claim_id;
    if v_claim_id is null then return null; end if;

    if p_campaign_key in ('winback-expired-offer', 'winback-canceled-offer') then
        insert into public.email_offer_claims as claim (
            user_id, offer_key, campaign_key, campaign_version, expires_at
        ) values (p_user_id, 'winback', p_campaign_key, p_campaign_version, now() + interval '14 days')
        on conflict (user_id, offer_key) do update set
            campaign_key = excluded.campaign_key,
            campaign_version = excluded.campaign_version,
            expires_at = excluded.expires_at,
            reserved_at = null,
            redeemed_at = null,
            paddle_transaction_id = null,
            updated_at = now();
        v_app_url := 'https://hellonod.app/open?target=subscription&offer=winback';
    elsif p_campaign_key in ('activation-never-recorded', 'trial-learning-day-1') then
        v_app_url := 'https://hellonod.app/open?target=record';
    elsif p_campaign_key in ('activation-second-meeting', 'trial-learning-day-4', 'activation-at-risk') then
        v_app_url := 'https://hellonod.app/open?target=history';
    elsif p_campaign_key in ('activation-chat-not-tried', 'trial-learning-day-10') then
        v_app_url := 'https://hellonod.app/open?target=ask';
    elsif p_campaign_key = 'activation-action-items-not-used' then
        v_app_url := 'https://hellonod.app/open?target=action-items';
    else
        v_app_url := 'https://hellonod.app/open?target=history';
    end if;

    v_token := public.issue_email_preference_token(p_user_id);
    v_first_name := coalesce(nullif(v_qualification ->> 'first_name', ''), 'there');
    v_session_count := nullif(v_qualification ->> 'session_count', '')::integer;
    v_open_commitments := nullif(v_qualification ->> 'open_commitments', '')::integer;
    v_days_left := nullif(v_qualification ->> 'days_left', '')::integer;

    v_payload := jsonb_build_object(
        'FIRST_NAME', v_first_name, 'first_name', v_first_name,
        'APP_URL', v_app_url, 'DOWNLOAD_URL', 'https://hellonod.app/get-nod',
        'CALENDLY_URL', 'https://calendly.com/meet-vlad-from-nod/30min',
        'calendly_url', 'https://calendly.com/meet-vlad-from-nod/30min',
        'PREFERENCE_URL', 'https://hellonod.app/email-preferences#' || coalesce(v_token, '')
    );

    -- Only campaigns whose template reads a count get it, and only when the
    -- number reads better than the template's own fallback.
    if p_campaign_key in (
        'trial-learning-day-4', 'trial-learning-day-10',
        'activation-chat-not-tried', 'winback-expired-offer',
        -- currently is_enabled = false, listed so enabling it needs no code change
        'founder-trial'
    ) and coalesce(v_session_count, 0) > 0 then
        v_payload := v_payload || jsonb_build_object('SESSION_COUNT', v_session_count);
    end if;

    if p_campaign_key in ('activation-action-items-not-used', 'activation-at-risk')
       and coalesce(v_open_commitments, 0) > 0 then
        v_payload := v_payload || jsonb_build_object('OPEN_COMMITMENTS', v_open_commitments);
    end if;

    if p_campaign_key = 'trial-learning-day-10' and coalesce(v_days_left, 0) > 0 then
        v_payload := v_payload || jsonb_build_object('DAYS_LEFT', v_days_left);
    end if;

    insert into public.email_outbox (
        claim_id, user_id, email, campaign_key, campaign_version,
        template_alias, consent_variant, qualification_reason, qualified_at, payload
    ) values (
        v_claim_id, p_user_id, lower(trim(v_qualification ->> 'email')),
        p_campaign_key, p_campaign_version, v_qualification ->> 'template_alias',
        v_qualification ->> 'variant', v_qualification ->> 'reason',
        (v_qualification ->> 'qualified_at')::timestamptz,
        v_payload
    ) returning id into v_outbox_id;
    return v_outbox_id;
end;
$$;

revoke all on function public.email_campaign_qualification(uuid, text, integer) from public, anon, authenticated;
revoke all on function public.enqueue_optional_email(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.email_campaign_qualification(uuid, text, integer) to service_role;
grant execute on function public.enqueue_optional_email(uuid, text, integer) to service_role;
