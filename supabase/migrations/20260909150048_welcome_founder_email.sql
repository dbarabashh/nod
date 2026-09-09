-- welcome-founder — the first email a new account receives.
--
-- Transactional: it answers the person's own action (creating the account), so
-- it carries no topic requirement and is not part of the optional programs.
-- Delivery still passes the master program gate, suppression, the outbox
-- idempotency key and `email_outbox_send_guard` like every other send.

insert into public.email_campaigns (
    campaign_key, version, email_class, priority, required_topics,
    template_aliases, cooldown, founder_cooldown, rollout_gate,
    accepted_policy_versions, rollout_mode, is_enabled
) values (
    'welcome-founder', 1, 'transactional', 4, array[]::text[],
    '{"en":{"transactional":"welcome-founder-v1-en"}}'::jsonb,
    interval '0', null, 'immediate',
    array['communications-v1', 'communications-v2'], 'off', true
)
on conflict (campaign_key, version) do update set
    email_class = excluded.email_class,
    priority = excluded.priority,
    required_topics = excluded.required_topics,
    template_aliases = excluded.template_aliases,
    cooldown = excluded.cooldown,
    rollout_gate = excluded.rollout_gate,
    accepted_policy_versions = excluded.accepted_policy_versions,
    is_enabled = true;

create or replace function public.queue_welcome_founder_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_first_name text;
begin
    v_first_name := coalesce(
        nullif(split_part(coalesce(new.raw_user_meta_data ->> 'full_name', ''), ' ', 1), ''),
        nullif(split_part(coalesce(new.raw_user_meta_data ->> 'name', ''), ' ', 1), ''),
        nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
        'there'
    );
    perform public.enqueue_transactional_email(
        new.id,
        'welcome-founder',
        'signup:' || new.id::text,
        jsonb_build_object(
            'FIRST_NAME', v_first_name,
            'first_name', v_first_name,
            'APP_URL', 'https://hellonod.app/open?target=record'
        )
    );
    return new;
exception when others then
    -- Signup must survive a broken mailer; the row is simply never queued.
    raise warning 'queue_welcome_founder_email skipped for %: %', new.id, sqlerrm;
    return new;
end;
$$;

revoke all on function public.queue_welcome_founder_email() from public, anon, authenticated;

-- Fires after on_auth_user_created_profile / _subscription, so the account rows
-- the guard and payload rely on already exist.
drop trigger if exists queue_welcome_founder_email on auth.users;
create trigger queue_welcome_founder_email
    after insert on auth.users
    for each row execute function public.queue_welcome_founder_email();

-- The guard's transactional branch is a whitelist: a campaign it does not name
-- is refused at send time. Teach it welcome-founder, leaving every existing
-- branch untouched.
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
    if not found or v_outbox.status <> 'sending' or not public.email_program_gate_open() then return false; end if;
    select * into v_campaign from public.email_campaigns
     where campaign_key = v_outbox.campaign_key and version = v_outbox.campaign_version and is_enabled;
    if not found then return false; end if;
    if exists (
        select 1 from public.email_suppressions suppression
         where suppression.email = v_outbox.email
           and (suppression.scope = 'all_email' or (suppression.scope = 'marketing' and v_campaign.email_class <> 'transactional'))
    ) then return false; end if;
    if v_campaign.email_class <> 'transactional' then
        v_qualification := public.email_campaign_qualification(v_outbox.user_id, v_outbox.campaign_key, v_outbox.campaign_version);
        if not coalesce((v_qualification ->> 'eligible')::boolean, false) then return false; end if;
        update public.email_outbox set
            consent_variant = v_qualification ->> 'variant',
            template_alias = v_qualification ->> 'template_alias', updated_at = now()
         where id = p_id and status = 'sending';
        return true;
    end if;
    select business_key into v_business_key from public.email_send_claims where id = v_outbox.claim_id;
    begin v_entity_id := split_part(v_business_key, ':', 2)::uuid; exception when others then return false; end;
    if v_outbox.campaign_key = 'referral-friend-subscribed' then
        return exists (select 1 from public.referrals where id = v_entity_id and referrer_user_id = v_outbox.user_id and status in ('activated', 'earned', 'rewarded'));
    elsif v_outbox.campaign_key = 'referral-reward-earned' then
        return exists (select 1 from public.reward_credits where id = v_entity_id and beneficiary_user_id = v_outbox.user_id and source_type = 'referral' and status in ('pending', 'payout_pending', 'applied') and available_at <= now() and expires_at > now());
    elsif v_outbox.campaign_key = 'referral-reward-applied' then
        return exists (select 1 from public.reward_payouts where id = v_entity_id and beneficiary_user_id = v_outbox.user_id and status = 'applied');
    elsif v_outbox.campaign_key = 'welcome-founder' then
        return v_entity_id = v_outbox.user_id
           and exists (
               select 1 from auth.users u
                where u.id = v_outbox.user_id
                  and lower(trim(coalesce(u.email, ''))) = v_outbox.email
           );
    end if;
    return false;
end;
$$;

revoke all on function public.email_outbox_send_guard(uuid) from public, anon, authenticated;
grant execute on function public.email_outbox_send_guard(uuid) to service_role;
