alter table public.email_campaigns
    add column accepted_policy_versions text[] not null default array['communications-v1'];

alter table public.email_campaigns
    add column rollout_mode text not null default 'off'
        check (rollout_mode in ('off', 'seed', 'limited', 'live'));

create table public.email_rollout_members (
    campaign_key text not null,
    campaign_version integer not null,
    user_id uuid not null references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (campaign_key, campaign_version, user_id),
    foreign key (campaign_key, campaign_version)
        references public.email_campaigns(campaign_key, version) on delete cascade
);

alter table public.email_rollout_members enable row level security;
revoke all on table public.email_rollout_members from public, anon, authenticated;
grant all on table public.email_rollout_members to service_role;

create table public.email_offer_claims (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    offer_key text not null check (offer_key = 'winback'),
    campaign_key text not null,
    campaign_version integer not null,
    expires_at timestamptz not null,
    reserved_at timestamptz,
    redeemed_at timestamptz,
    paddle_transaction_id text unique,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (user_id, offer_key),
    foreign key (campaign_key, campaign_version)
        references public.email_campaigns(campaign_key, version),
    constraint email_offer_claim_expiry check (expires_at > created_at)
);

alter table public.email_offer_claims enable row level security;
revoke all on table public.email_offer_claims from public, anon, authenticated;
grant all on table public.email_offer_claims to service_role;

update public.email_program_config
   set policy_version = 'communications-v2',
       prompt_version = 'communications-v2',
       policy_published_at = null,
       program_not_before = null,
       updated_at = now()
 where singleton;

update public.email_campaigns
   set rollout_mode = 'off',
       accepted_policy_versions = case
           when required_topics = array['lifecycle_guidance']::text[]
               then array['communications-v1', 'communications-v2']
           else array['communications-v1', 'communications-v2']
       end
 where email_class <> 'transactional';

update public.email_campaigns
   set is_enabled = false
 where campaign_key in (
    'founder-canceled', 'founder-expired', 'founder-trial',
    'founder-active', 'founder-annual'
 );

insert into public.email_campaigns (
    campaign_key, version, email_class, priority, required_topics,
    template_aliases, cooldown, founder_cooldown, rollout_gate,
    accepted_policy_versions, rollout_mode
) values
    ('trial-learning-day-1', 1, 'marketing', 10, array['lifecycle_guidance'],
        '{"en":{"guidance":"trial-learning-day-1-v1-en"}}', interval '72 hours', null, 'marketing',
        array['communications-v2'], 'off'),
    ('trial-learning-day-4', 1, 'marketing', 11, array['lifecycle_guidance'],
        '{"en":{"guidance":"trial-learning-day-4-v1-en"}}', interval '72 hours', null, 'marketing',
        array['communications-v2'], 'off'),
    ('trial-learning-day-10', 1, 'marketing', 12, array['lifecycle_guidance'],
        '{"en":{"guidance":"trial-learning-day-10-v1-en"}}', interval '72 hours', null, 'marketing',
        array['communications-v2'], 'off'),
    ('activation-second-meeting', 1, 'marketing', 35, array['lifecycle_guidance'],
        '{"en":{"guidance":"activation-second-meeting-v1-en"}}', interval '14 days', null, 'marketing',
        array['communications-v1', 'communications-v2'], 'off'),
    ('winback-expired-offer', 1, 'marketing', 110, array['product_updates'],
        '{"en":{"default":"winback-expired-offer-v1-en"}}', interval '14 days', null, 'marketing',
        array['communications-v1', 'communications-v2'], 'off'),
    ('winback-canceled-offer', 1, 'marketing', 111, array['product_updates'],
        '{"en":{"default":"winback-canceled-offer-v1-en"}}', interval '14 days', null, 'marketing',
        array['communications-v1', 'communications-v2'], 'off'),
    ('winback-expired-feedback', 1, 'research', 120, array['founder_research'],
        '{"en":{"default":"winback-expired-feedback-v1-en"}}', interval '14 days', interval '30 days', 'marketing',
        array['communications-v1', 'communications-v2'], 'off'),
    ('winback-canceled-feedback', 1, 'research', 121, array['founder_research'],
        '{"en":{"default":"winback-canceled-feedback-v1-en"}}', interval '14 days', interval '30 days', 'marketing',
        array['communications-v1', 'communications-v2'], 'off')
on conflict (campaign_key, version) do update set
    email_class = excluded.email_class,
    priority = excluded.priority,
    required_topics = excluded.required_topics,
    template_aliases = excluded.template_aliases,
    cooldown = excluded.cooldown,
    founder_cooldown = excluded.founder_cooldown,
    accepted_policy_versions = excluded.accepted_policy_versions,
    rollout_mode = 'off',
    is_enabled = true;

update public.email_campaigns
   set template_aliases = case campaign_key
       when 'activation-never-recorded' then '{"en":{"guidance":"activation-never-recorded-v2-en"}}'::jsonb
       when 'activation-at-risk' then '{"en":{"guidance":"activation-at-risk-v2-en"}}'::jsonb
       when 'activation-chat-not-tried' then '{"en":{"guidance":"activation-chat-not-tried-v2-en"}}'::jsonb
       when 'activation-action-items-not-used' then '{"en":{"guidance":"activation-action-items-not-used-v2-en"}}'::jsonb
       else template_aliases
   end
 where campaign_key in (
    'activation-never-recorded', 'activation-at-risk',
    'activation-chat-not-tried', 'activation-action-items-not-used'
 );

create or replace function public.get_email_preferences()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := auth.uid();
    v_prompt_version text;
begin
    if v_user_id is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    select prompt_version into v_prompt_version
      from public.email_program_config where singleton;

    return jsonb_build_object(
        'preferences', (
            select jsonb_agg(jsonb_build_object(
                'topic', topics.topic,
                'status', coalesce(preference.status, 'unsubscribed'),
                'policy_version', preference.policy_version,
                'source', preference.source,
                'prompted_at', preference.prompted_at,
                'consented_at', preference.consented_at,
                'unsubscribed_at', preference.unsubscribed_at
            ) order by topics.position)
            from (values
                ('product_updates', 1),
                ('lifecycle_guidance', 2),
                ('founder_research', 3)
            ) as topics(topic, position)
            left join public.email_preferences preference
              on preference.user_id = v_user_id and preference.topic = topics.topic
        ),
        'prompt_seen', exists (
            select 1 from public.email_consent_prompts prompt
             where prompt.user_id = v_user_id and prompt.prompt_version = v_prompt_version
        ),
        'has_seen_v1_prompt', exists (
            select 1 from public.email_consent_prompts prompt
             where prompt.user_id = v_user_id and prompt.prompt_version = 'communications-v1'
        ),
        'prompt_version', v_prompt_version
    );
end;
$$;

create or replace function public.set_email_preference(
    p_topic text,
    p_status text,
    p_policy_version text,
    p_source text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := auth.uid();
    v_expected_policy_version text;
    v_row public.email_preferences%rowtype;
begin
    if v_user_id is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if p_topic not in ('product_updates', 'lifecycle_guidance', 'founder_research')
       or p_status not in ('subscribed', 'unsubscribed')
       or p_source not in ('onboarding_prompt', 'existing_user_prompt', 'macos_settings') then
        raise exception 'unsupported email preference request' using errcode = '22023';
    end if;

    v_expected_policy_version := case
        when p_topic = 'lifecycle_guidance' then 'communications-v2'
        else 'communications-v1'
    end;
    if p_policy_version is distinct from v_expected_policy_version then
        raise exception 'stale consent policy version' using errcode = '22023';
    end if;

    insert into public.email_preferences as current_preference (
        user_id, topic, status, policy_version, source,
        prompted_at, consented_at, unsubscribed_at, updated_at
    ) values (
        v_user_id, p_topic, p_status, v_expected_policy_version, p_source,
        case when p_source in ('onboarding_prompt', 'existing_user_prompt') then now() end,
        case when p_status = 'subscribed' then now() end,
        case when p_status = 'unsubscribed' then now() end,
        now()
    )
    on conflict (user_id, topic) do update set
        status = excluded.status,
        policy_version = excluded.policy_version,
        source = excluded.source,
        prompted_at = coalesce(excluded.prompted_at, current_preference.prompted_at),
        consented_at = case when excluded.status = 'subscribed' then now() else current_preference.consented_at end,
        unsubscribed_at = case when excluded.status = 'unsubscribed' then now() end,
        updated_at = now()
    returning * into v_row;

    return to_jsonb(v_row);
end;
$$;

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
    positive_meetings as (
        select m.user_id, m.ended_at,
               row_number() over (partition by m.user_id order by m.ended_at) as meeting_number,
               min(m.ended_at) over (partition by m.user_id) as first_completed_at
          from public.meetings m
         where m.deleted_at is null and m.ended_at > m.started_at
    ),
    meeting_stats as (
        select user_id,
               count(*)::integer as completed_meetings,
               max(ended_at) as last_completed_at,
               max(ended_at) filter (
                   where meeting_number = 2 and ended_at <= first_completed_at + interval '3 days'
               ) as second_completed_at
          from positive_meetings
         group by user_id
    ),
    value_signal as (
        select signal.user_id, max(signal.occurred_at) as last_meaningful_value_at
          from (
              select m.user_id, m.ended_at as occurred_at
                from public.meetings m
               where m.deleted_at is null and m.ended_at > m.started_at
              union all
              select e.user_id, e.occurred_at
                from public.product_events e
               where e.event in (
                   'summary_viewed', 'transcript_viewed', 'action_items_viewed',
                   'content_copied', 'meeting_exported', 'ai_action_completed'
               )
              union all
              select c.user_id, c.created_at from public.chat_messages c where c.role = 'user'
              union all
              select k.user_id, k.created_at from public.knowledge_messages k where k.role = 'user'
              union all
              select a.user_id, a.done_at from public.action_items a where a.done_at is not null
          ) signal
         group by signal.user_id
    ),
    chat_signal as (
        select user_id, true as has_user_chat
          from (
              select c.user_id from public.chat_messages c where c.role = 'user'
              union
              select k.user_id from public.knowledge_messages k where k.role = 'user'
          ) chats
         group by user_id
    ),
    action_item_signal as (
        select a.user_id, count(*) filter (where not a.done)::integer as open_action_items
          from public.action_items a where a.deleted_at is null group by a.user_id
    ),
    action_item_views as (
        select e.user_id, true as has_viewed_action_items
          from public.product_events e where e.event = 'action_items_viewed' group by e.user_id
    ),
    assembled as (
        select
            account.user_id, account.email, account.first_name, account.signup_at,
            subscription.plan, price.billing_cycle, subscription.status as subscription_status,
            subscription.converted_at, subscription.trial_ends_at,
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
    select assembled.*,
        assembled.second_completed_at is not null as is_activated,
        assembled.completed_meetings = 0
            and assembled.signup_at <= now() - interval '2 days'
            and assembled.subscription_status in ('trialing', 'active') as is_never_recorded,
        assembled.second_completed_at is not null
            and assembled.last_meaningful_value_at <= now() - interval '7 days'
            and assembled.subscription_status in ('trialing', 'active') as is_at_risk,
        assembled.second_completed_at is not null and not assembled.has_user_chat
            and assembled.subscription_status in ('trialing', 'active') as is_chat_not_tried,
        assembled.second_completed_at is not null
            and assembled.open_action_items > 0 and not assembled.has_viewed_action_items
            and assembled.subscription_status in ('trialing', 'active') as is_action_items_not_used
      from assembled;
$$;

create or replace function public.email_campaign_rollout_allows(
    p_campaign_key text,
    p_campaign_version integer,
    p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select case campaign.rollout_mode
        when 'live' then true
        when 'seed' then exists (
            select 1 from public.email_rollout_members member
             where member.campaign_key = campaign.campaign_key
               and member.campaign_version = campaign.version
               and member.user_id = p_user_id
        )
        when 'limited' then (
            exists (
                select 1 from public.email_outbox current_outbox
                 where current_outbox.campaign_key = campaign.campaign_key
                   and current_outbox.campaign_version = campaign.version
                   and current_outbox.user_id = p_user_id
                   and current_outbox.status in ('queued', 'sending')
            )
            or
            exists (
                select 1 from public.email_rollout_members member
                 where member.campaign_key = campaign.campaign_key
                   and member.campaign_version = campaign.version
                   and member.user_id = p_user_id
            )
            or (
                select count(*) < 2
                  from public.email_outbox outbox
                  join public.email_campaigns sent_campaign
                    on sent_campaign.campaign_key = outbox.campaign_key
                   and sent_campaign.version = outbox.campaign_version
                 where sent_campaign.email_class <> 'transactional'
                   and coalesce(outbox.accepted_at, outbox.request_started_at, outbox.created_at)
                       > now() - interval '24 hours'
                   and outbox.status in ('sending', 'accepted', 'delivery_unknown')
            )
        )
        else false
    end
      from public.email_campaigns campaign
     where campaign.campaign_key = p_campaign_key and campaign.version = p_campaign_version;
$$;

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
    elsif p_campaign_key = 'activation-at-risk' and v_snapshot.is_at_risk then
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
        'email', v_snapshot.email, 'first_name', v_snapshot.first_name
    );
end;
$$;

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
    select not exists (
        select 1 from public.email_outbox outbox
         where outbox.user_id = p_user_id
           and outbox.status in ('queued', 'sending', 'accepted', 'delivery_unknown')
           and coalesce(outbox.accepted_at, outbox.request_started_at, outbox.created_at)
               > now() - case when p_campaign_key like 'trial-learning-%' then interval '72 hours' else interval '14 days' end
    ) and (
        p_email_class <> 'research' or not exists (
            select 1 from public.email_outbox outbox
            join public.email_campaigns campaign
              on campaign.campaign_key = outbox.campaign_key and campaign.version = outbox.campaign_version
             where outbox.user_id = p_user_id and campaign.email_class = 'research'
               and outbox.status in ('queued', 'sending', 'accepted', 'delivery_unknown')
               and coalesce(outbox.accepted_at, outbox.request_started_at, outbox.created_at) > now() - interval '30 days'
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
    v_app_url text;
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
    insert into public.email_outbox (
        claim_id, user_id, email, campaign_key, campaign_version,
        template_alias, consent_variant, qualification_reason, qualified_at, payload
    ) values (
        v_claim_id, p_user_id, lower(trim(v_qualification ->> 'email')),
        p_campaign_key, p_campaign_version, v_qualification ->> 'template_alias',
        v_qualification ->> 'variant', v_qualification ->> 'reason',
        (v_qualification ->> 'qualified_at')::timestamptz,
        jsonb_build_object(
            'FIRST_NAME', v_first_name, 'first_name', v_first_name,
            'APP_URL', v_app_url, 'DOWNLOAD_URL', 'https://hellonod.app/get-nod',
            'CALENDLY_URL', 'https://calendly.com/meet-vlad-from-nod/30min',
            'calendly_url', 'https://calendly.com/meet-vlad-from-nod/30min',
            'PREFERENCE_URL', 'https://hellonod.app/email-preferences#' || coalesce(v_token, '')
        )
    ) returning id into v_outbox_id;
    return v_outbox_id;
end;
$$;

create or replace function public.reserve_email_offer_claim(
    p_user_id uuid,
    p_offer_key text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_claim_id uuid;
begin
    if p_offer_key <> 'winback' then return null; end if;
    perform pg_advisory_xact_lock(hashtext('email-offer:' || p_user_id::text || ':' || p_offer_key));
    update public.email_offer_claims
       set reserved_at = now(), updated_at = now()
     where user_id = p_user_id and offer_key = p_offer_key
       and expires_at > now() and redeemed_at is null
       and (reserved_at is null or reserved_at < now() - interval '15 minutes')
    returning id into v_claim_id;
    return v_claim_id;
end;
$$;

create or replace function public.release_email_offer_claim(
    p_claim_id uuid,
    p_user_id uuid
)
returns void
language sql
security definer
set search_path = ''
as $$
    update public.email_offer_claims
       set reserved_at = null, updated_at = now()
     where id = p_claim_id and user_id = p_user_id and redeemed_at is null
       and paddle_transaction_id is null;
$$;

create or replace function public.bind_email_offer_transaction(
    p_claim_id uuid,
    p_user_id uuid,
    p_transaction_id text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_bound boolean;
begin
    update public.email_offer_claims
       set paddle_transaction_id = p_transaction_id, updated_at = now()
     where id = p_claim_id and user_id = p_user_id and reserved_at is not null
       and expires_at > now() and redeemed_at is null and paddle_transaction_id is null
    returning true into v_bound;
    return coalesce(v_bound, false);
end;
$$;

create or replace function public.redeem_email_offer_transaction(
    p_claim_id uuid,
    p_user_id uuid,
    p_transaction_id text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_redeemed boolean;
begin
    update public.email_offer_claims
       set redeemed_at = coalesce(redeemed_at, now()), updated_at = now()
     where id = p_claim_id and user_id = p_user_id
       and paddle_transaction_id = p_transaction_id and expires_at > created_at
    returning true into v_redeemed;
    return coalesce(v_redeemed, false);
end;
$$;

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
    end if;
    return false;
end;
$$;

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
              select m.ended_at as occurred_at
                from public.meetings m
               where m.user_id = outbox.user_id and m.deleted_at is null and m.ended_at > m.started_at
                 and outbox.campaign_key in ('activation-never-recorded', 'activation-second-meeting', 'activation-at-risk', 'trial-learning-day-1', 'trial-learning-day-4')
              union all
              select c.created_at from public.chat_messages c
               where c.user_id = outbox.user_id and c.role = 'user'
                 and outbox.campaign_key in ('activation-chat-not-tried', 'activation-at-risk', 'trial-learning-day-10')
              union all
              select k.created_at from public.knowledge_messages k
               where k.user_id = outbox.user_id and k.role = 'user'
                 and outbox.campaign_key in ('activation-chat-not-tried', 'activation-at-risk', 'trial-learning-day-10')
              union all
              select e.occurred_at from public.product_events e
               where e.user_id = outbox.user_id
                 and ((outbox.campaign_key = 'activation-action-items-not-used' and e.event = 'action_items_viewed')
                   or (outbox.campaign_key = 'activation-at-risk' and e.event in ('summary_viewed', 'transcript_viewed', 'content_copied', 'meeting_exported', 'ai_action_completed')))
              union all
              select s.converted_at from public.subscriptions s
               where s.user_id = outbox.user_id and s.converted_at is not null
                 and outbox.campaign_key in ('winback-expired-offer', 'winback-canceled-offer')
          ) activity
         where outbox.status in ('accepted', 'delivery_unknown') and outbox.conversion_at is null
           and activity.occurred_at > coalesce(outbox.delivered_at, outbox.accepted_at)
           and activity.occurred_at <= coalesce(outbox.delivered_at, outbox.accepted_at) + interval '14 days'
         group by outbox.id
    )
    update public.email_outbox outbox set conversion_at = eligible.conversion_at, updated_at = now()
      from eligible where outbox.id = eligible.id;
    get diagnostics v_updated = row_count;
    return v_updated;
end;
$$;

drop function if exists public.founder_email_outreach();
create function public.founder_email_outreach()
returns table (
    outreach_id uuid,
    user_id uuid,
    email text,
    campaign_key text,
    campaign_version integer,
    email_class text,
    rollout_mode text,
    accepted_policy_versions text[],
    qualification_reason text,
    consent_variant text,
    queue_status text,
    delivery_status text,
    qualified_at timestamptz,
    queued_at timestamptz,
    sent_at timestamptz,
    delivered_at timestamptz,
    attempts integer,
    last_error text,
    converted_within_14d boolean,
    conversion_at timestamptz,
    offer_expires_at timestamptz,
    offer_redeemed_at timestamptz
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
        outbox.id, outbox.user_id, outbox.email, outbox.campaign_key,
        outbox.campaign_version, campaign.email_class, campaign.rollout_mode,
        campaign.accepted_policy_versions, outbox.qualification_reason,
        outbox.consent_variant, outbox.status, outbox.provider_status,
        outbox.qualified_at, outbox.created_at, outbox.accepted_at,
        outbox.delivered_at, outbox.attempts, outbox.last_error,
        outbox.conversion_at is not null, outbox.conversion_at,
        offer.expires_at, offer.redeemed_at
      from public.email_outbox outbox
      join public.email_campaigns campaign
        on campaign.campaign_key = outbox.campaign_key and campaign.version = outbox.campaign_version
      left join public.email_offer_claims offer
        on offer.user_id = outbox.user_id and offer.campaign_key = outbox.campaign_key
     where outbox.user_id <> all(public._excluded_user_ids())
     order by outbox.created_at desc;
end;
$$;

create or replace function public.founder_email_campaigns()
returns table (
    campaign_key text,
    campaign_version integer,
    email_class text,
    required_topics text[],
    accepted_policy_versions text[],
    rollout_mode text,
    is_enabled boolean,
    claimed_users bigint,
    queued bigint,
    delivered bigint,
    converted bigint,
    active_offers bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    perform public._assert_founder();
    return query
    select campaign.campaign_key, campaign.version, campaign.email_class,
           campaign.required_topics, campaign.accepted_policy_versions,
           campaign.rollout_mode, campaign.is_enabled,
           count(distinct claim.user_id),
           count(distinct outbox.id) filter (where outbox.status in ('queued', 'sending')),
           count(distinct outbox.id) filter (where outbox.provider_status = 'delivered'),
           count(distinct outbox.id) filter (where outbox.conversion_at is not null),
           count(distinct offer.id) filter (where offer.expires_at > now() and offer.redeemed_at is null)
      from public.email_campaigns campaign
      left join public.email_send_claims claim
        on claim.campaign_key = campaign.campaign_key and claim.campaign_version = campaign.version
       and claim.user_id <> all(public._excluded_user_ids())
      left join public.email_outbox outbox on outbox.claim_id = claim.id
      left join public.email_offer_claims offer
        on offer.campaign_key = campaign.campaign_key and offer.campaign_version = campaign.version
     where campaign.email_class <> 'transactional'
     group by campaign.campaign_key, campaign.version, campaign.email_class,
              campaign.required_topics, campaign.accepted_policy_versions,
              campaign.rollout_mode, campaign.is_enabled
     order by campaign.priority;
end;
$$;

revoke all on function public.founder_email_outreach() from public, anon;
revoke all on function public.founder_email_campaigns() from public, anon;
grant execute on function public.founder_email_outreach() to authenticated;
grant execute on function public.founder_email_campaigns() to authenticated;

revoke all on function public.email_campaign_rollout_allows(text, integer, uuid) from public, anon, authenticated;
revoke all on function public.optional_email_cooldown_clear(uuid, text, text) from public, anon, authenticated;
revoke all on function public.reserve_email_offer_claim(uuid, text) from public, anon, authenticated;
revoke all on function public.release_email_offer_claim(uuid, uuid) from public, anon, authenticated;
revoke all on function public.bind_email_offer_transaction(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.redeem_email_offer_transaction(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.email_campaign_rollout_allows(text, integer, uuid) to service_role;
grant execute on function public.optional_email_cooldown_clear(uuid, text, text) to service_role;
grant execute on function public.reserve_email_offer_claim(uuid, text) to service_role;
grant execute on function public.release_email_offer_claim(uuid, uuid) to service_role;
grant execute on function public.bind_email_offer_transaction(uuid, uuid, text) to service_role;
grant execute on function public.redeem_email_offer_transaction(uuid, uuid, text) to service_role;
