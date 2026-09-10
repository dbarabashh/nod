-- The booking link in every lifecycle email now points at the person who
-- sends them.
--
-- `enqueue_optional_email` writes CALENDLY_URL/calendly_url into every
-- optional email's payload, and both still held a departed colleague's
-- Calendly. Nine published templates render it as "book a slot"; two more
-- declare it without using it. Sandbox at the time of writing:
-- `enqueue_optional_email` contained the old host, so every campaign that
-- offered a call sent people to a calendar nobody reads.
--
-- The whole function is restated because Postgres has no way to patch one
-- literal inside a body; only the two URLs differ from `20260909163000`.
--
-- The Resend templates carry the same URL again as each variable's fallback,
-- and those were updated in the Resend dashboard in the same change — the
-- fallback only fires for a send path that omits the variable, so the two
-- have to agree.
--
-- The variable keeps its vendor name for now. Renaming it to something
-- neutral means sending both keys, switching every template, then dropping
-- the old one — a separate expand/migrate/contract, not a rider on this.

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
        'CALENDLY_URL', 'https://cal.com/dima-from-nod/15min',
        'calendly_url', 'https://cal.com/dima-from-nod/15min',
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
