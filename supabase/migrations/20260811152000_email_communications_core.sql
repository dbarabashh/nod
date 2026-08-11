create extension if not exists pgcrypto;

-- One program-wide gate. NOD-76 accepts "no customer contact sync or external
-- send occurs before the gate", so this covers transactional referral notices
-- too: Resend itself is only a disclosed subprocessor once the notice period
-- completes. Consent and cadence are separate, narrower checks layered on top.
create table public.email_program_config (
    singleton boolean primary key default true check (singleton),
    policy_version text not null,
    prompt_version text not null,
    policy_published_at timestamptz,
    program_not_before timestamptz,
    updated_at timestamptz not null default now(),
    constraint email_program_notice_period check (
        (policy_published_at is null and program_not_before is null)
        or program_not_before >= policy_published_at + interval '30 days'
    )
);

insert into public.email_program_config (singleton, policy_version, prompt_version)
values (true, 'communications-v1', 'communications-v1');

alter table public.email_program_config enable row level security;

create table public.email_preferences (
    user_id uuid not null references auth.users(id) on delete cascade,
    topic text not null check (topic in ('product_updates', 'lifecycle_guidance', 'founder_research')),
    status text not null check (status in ('subscribed', 'unsubscribed')),
    policy_version text not null,
    source text not null check (source in (
        'onboarding_prompt', 'existing_user_prompt', 'macos_settings',
        'web_preferences', 'resend_webhook', 'account_deletion'
    )),
    prompted_at timestamptz,
    consented_at timestamptz,
    unsubscribed_at timestamptz,
    updated_at timestamptz not null default now(),
    primary key (user_id, topic),
    constraint email_preference_timestamps check (
        (status = 'subscribed' and consented_at is not null and unsubscribed_at is null)
        or (status = 'unsubscribed' and unsubscribed_at is not null)
    )
);

alter table public.email_preferences enable row level security;

create table public.email_consent_prompts (
    user_id uuid not null references auth.users(id) on delete cascade,
    prompt_version text not null,
    source text not null check (source in ('onboarding_prompt', 'existing_user_prompt')),
    seen_at timestamptz not null default now(),
    primary key (user_id, prompt_version)
);

alter table public.email_consent_prompts enable row level security;

-- `rollout_gate` stages campaigns behind the program gate: `immediate` goes the
-- moment the gate opens, `marketing` is held for a separate deliberate step.
create table public.email_campaigns (
    campaign_key text not null,
    version integer not null check (version > 0),
    email_class text not null check (email_class in ('transactional', 'marketing', 'research')),
    priority integer not null check (priority > 0),
    required_topics text[] not null default '{}',
    template_aliases jsonb not null,
    cooldown interval not null default interval '14 days',
    founder_cooldown interval,
    rollout_gate text not null check (rollout_gate in ('immediate', 'marketing')),
    is_enabled boolean not null default true,
    created_at timestamptz not null default now(),
    primary key (campaign_key, version),
    constraint email_campaign_topics_known
        check (required_topics <@ array['product_updates', 'lifecycle_guidance', 'founder_research']::text[]),
    constraint email_campaign_aliases_object check (jsonb_typeof(template_aliases) = 'object')
);

alter table public.email_campaigns enable row level security;

-- Aliases match published Resend templates exactly; the worker refuses to send
-- an alias that is not published, so a typo here fails closed.
insert into public.email_campaigns (
    campaign_key, version, email_class, priority, required_topics,
    template_aliases, cooldown, founder_cooldown, rollout_gate
) values
    ('referral-friend-subscribed', 1, 'transactional', 1, '{}',
        '{"en":{"transactional":"referral-friend-subscribed-v1-en"}}', interval '0', null, 'immediate'),
    ('referral-reward-earned', 1, 'transactional', 2, '{}',
        '{"en":{"transactional":"referral-reward-earned-v1-en"}}', interval '0', null, 'immediate'),
    ('referral-reward-applied', 1, 'transactional', 3, '{}',
        '{"en":{"transactional":"referral-reward-applied-v1-en"}}', interval '0', null, 'immediate'),
    ('founder-canceled', 1, 'research', 10, array['founder_research'],
        '{"en":{"default":"founder-canceled-en-1"}}', interval '14 days', interval '30 days', 'marketing'),
    ('founder-expired', 1, 'research', 20, array['founder_research'],
        '{"en":{"default":"founder-expired-en-1"}}', interval '14 days', interval '30 days', 'marketing'),
    ('activation-at-risk', 1, 'marketing', 30, array['lifecycle_guidance'],
        '{"en":{"guidance":"activation-at-risk-v1-en","founder":"activation-at-risk-founder-v1-en"}}', interval '14 days', null, 'marketing'),
    ('activation-never-recorded', 1, 'marketing', 40, array['lifecycle_guidance'],
        '{"en":{"guidance":"activation-never-recorded-v1-en","founder":"activation-never-recorded-founder-v1-en"}}', interval '14 days', null, 'marketing'),
    ('founder-trial', 1, 'research', 50, array['founder_research'],
        '{"en":{"default":"founder-trial-en"}}', interval '14 days', interval '30 days', 'marketing'),
    ('founder-annual', 1, 'research', 60, array['founder_research'],
        '{"en":{"default":"founder-annual-en-1"}}', interval '14 days', interval '30 days', 'marketing'),
    ('founder-active', 1, 'research', 70, array['founder_research'],
        '{"en":{"default":"founder-active-en-1"}}', interval '14 days', interval '30 days', 'marketing'),
    ('activation-chat-not-tried', 1, 'marketing', 80, array['lifecycle_guidance'],
        '{"en":{"guidance":"activation-chat-not-tried-v1-en","founder":"activation-chat-not-tried-founder-v1-en"}}', interval '14 days', null, 'marketing'),
    ('activation-action-items-not-used', 1, 'marketing', 90, array['lifecycle_guidance'],
        '{"en":{"guidance":"activation-action-items-not-used-v1-en","founder":"activation-action-items-not-used-founder-v1-en"}}', interval '14 days', null, 'marketing'),
    ('referral-launch', 1, 'marketing', 100, array['product_updates'],
        '{"en":{"default":"referral-program-launch-v1-en"}}', interval '14 days', null, 'marketing');

-- Deduplication that outlives delivery logs: the claim is the permanent record
-- that this campaign version was already sent for this business key.
create table public.email_send_claims (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    campaign_key text not null,
    campaign_version integer not null,
    business_key text not null,
    idempotency_key text not null unique,
    claimed_at timestamptz not null default now(),
    unique (campaign_key, campaign_version, user_id, business_key),
    foreign key (campaign_key, campaign_version)
        references public.email_campaigns(campaign_key, version)
);

alter table public.email_send_claims enable row level security;

create table public.email_outbox (
    id uuid primary key default gen_random_uuid(),
    claim_id uuid not null unique references public.email_send_claims(id) on delete cascade,
    user_id uuid not null references auth.users(id) on delete cascade,
    email text not null,
    campaign_key text not null,
    campaign_version integer not null,
    template_alias text not null,
    locale text not null default 'en' check (locale = 'en'),
    consent_variant text not null check (consent_variant in ('transactional', 'default', 'guidance', 'founder')),
    qualification_reason text not null,
    qualified_at timestamptz not null,
    payload jsonb not null default '{}'::jsonb,
    status text not null default 'queued' check (status in (
        'queued', 'sending', 'accepted', 'delivery_unknown', 'failed', 'suppressed', 'canceled'
    )),
    provider_status text check (provider_status is null or provider_status in (
        'accepted', 'delivered', 'failed', 'bounced', 'complained', 'suppressed'
    )),
    provider_status_at timestamptz,
    provider_email_id text unique,
    attempts integer not null default 0,
    available_at timestamptz not null default now(),
    -- A queued row that never got a chance to send must go stale rather than
    -- fire months later when the gate finally opens.
    expires_at timestamptz not null default now() + interval '30 days',
    request_started_at timestamptz,
    accepted_at timestamptz,
    delivered_at timestamptz,
    conversion_at timestamptz,
    last_error text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    foreign key (campaign_key, campaign_version)
        references public.email_campaigns(campaign_key, version),
    constraint email_outbox_lowercase_email check (email = lower(trim(email)))
);

create index email_outbox_ready_idx
    on public.email_outbox (available_at, created_at)
    where status = 'queued';
create index email_outbox_user_cadence_idx
    on public.email_outbox (user_id, accepted_at desc)
    where status in ('accepted', 'delivery_unknown');
create index email_outbox_provider_idx
    on public.email_outbox (provider_email_id)
    where provider_email_id is not null;

alter table public.email_outbox enable row level security;

create table public.email_webhook_events (
    provider_event_id text primary key,
    event_type text not null,
    provider_email_id text,
    email text,
    payload jsonb not null,
    occurred_at timestamptz,
    received_at timestamptz not null default now(),
    processed_at timestamptz
);

create index email_webhook_provider_email_idx
    on public.email_webhook_events (provider_email_id, received_at)
    where provider_email_id is not null;

alter table public.email_webhook_events enable row level security;

create table public.email_suppressions (
    email text not null,
    scope text not null check (scope in ('marketing', 'all_email')),
    reason text not null check (reason in ('unsubscribe', 'complaint', 'bounce', 'provider_suppression', 'account_deletion')),
    source text not null,
    provider_event_id text,
    suppressed_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    primary key (email, scope),
    constraint email_suppressions_lowercase check (email = lower(trim(email)))
);

alter table public.email_suppressions enable row level security;

create table public.resend_contact_sync (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    email text not null,
    topic text not null check (topic in ('product_updates', 'lifecycle_guidance', 'founder_research')),
    desired_status text not null check (desired_status in ('subscribed', 'unsubscribed')),
    policy_version text not null,
    status text not null default 'queued' check (status in ('queued', 'syncing', 'synced', 'failed')),
    attempts integer not null default 0,
    available_at timestamptz not null default now(),
    last_error text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (user_id, topic),
    constraint resend_contact_sync_lowercase check (email = lower(trim(email)))
);

create index resend_contact_sync_ready_idx
    on public.resend_contact_sync (available_at, updated_at)
    where status = 'queued';

alter table public.resend_contact_sync enable row level security;

-- Deleting an account must also delete the provider-side contact. The row
-- survives the cascade by design (hashed email only), or the erasure would have
-- nothing left to act on.
create table public.resend_contact_deletions (
    id uuid primary key default gen_random_uuid(),
    email text,
    email_hash text not null unique,
    status text not null default 'queued' check (status in ('queued', 'deleting', 'deleted', 'failed')),
    attempts integer not null default 0,
    available_at timestamptz not null default now(),
    last_error text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint resend_contact_deletions_lowercase check (email is null or email = lower(trim(email)))
);

create index resend_contact_deletions_ready_idx
    on public.resend_contact_deletions (available_at, updated_at)
    where status = 'queued';

alter table public.resend_contact_deletions enable row level security;

create table public.email_preference_tokens (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    token_hash text not null unique,
    expires_at timestamptz not null,
    created_at timestamptz not null default now(),
    last_used_at timestamptz,
    constraint email_preference_tokens_valid_expiry check (expires_at > created_at)
);

create index email_preference_tokens_user_idx
    on public.email_preference_tokens (user_id, expires_at desc);

alter table public.email_preference_tokens enable row level security;

-- `subscriptions` holds current state only. Cohorts like "entered annual 7-30
-- days ago" need history, so billing transitions are journalled here.
create table public.email_lifecycle_events (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    event text not null check (event in ('paid_converted', 'yearly_entered', 'subscription_canceled')),
    occurred_at timestamptz not null,
    source text not null check (source in ('paddle_webhook', 'migration_backfill')),
    source_event_id text,
    dedupe_key text not null unique,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now()
);

create index email_lifecycle_user_event_idx
    on public.email_lifecycle_events (user_id, event, occurred_at desc);

alter table public.email_lifecycle_events enable row level security;

revoke all on table public.email_program_config from public, anon, authenticated;
revoke all on table public.email_preferences from public, anon, authenticated;
revoke all on table public.email_consent_prompts from public, anon, authenticated;
revoke all on table public.email_campaigns from public, anon, authenticated;
revoke all on table public.email_send_claims from public, anon, authenticated;
revoke all on table public.email_outbox from public, anon, authenticated;
revoke all on table public.email_webhook_events from public, anon, authenticated;
revoke all on table public.email_suppressions from public, anon, authenticated;
revoke all on table public.resend_contact_sync from public, anon, authenticated;
revoke all on table public.resend_contact_deletions from public, anon, authenticated;
revoke all on table public.email_preference_tokens from public, anon, authenticated;
revoke all on table public.email_lifecycle_events from public, anon, authenticated;

grant all on table public.email_program_config to service_role;
grant all on table public.email_preferences to service_role;
grant all on table public.email_consent_prompts to service_role;
grant all on table public.email_campaigns to service_role;
grant all on table public.email_send_claims to service_role;
grant all on table public.email_outbox to service_role;
grant all on table public.email_webhook_events to service_role;
grant all on table public.email_suppressions to service_role;
grant all on table public.resend_contact_sync to service_role;
grant all on table public.resend_contact_deletions to service_role;
grant all on table public.email_preference_tokens to service_role;
grant all on table public.email_lifecycle_events to service_role;

-- Nothing reaches Resend before the notice period completes — the single fact
-- every claim and send path checks.
create or replace function public.email_program_gate_open()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1 from public.email_program_config
         where singleton
           and program_not_before is not null
           and now() >= program_not_before
    );
$$;

create or replace function public.configure_email_policy_gate(p_policy_published_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_not_before timestamptz;
begin
    if p_policy_published_at is null then
        return jsonb_build_object('configured', false, 'error', 'policy_publication_required');
    end if;
    v_not_before := p_policy_published_at + interval '30 days';
    update public.email_program_config
       set policy_published_at = p_policy_published_at,
           program_not_before = v_not_before,
           updated_at = now()
     where singleton;
    return jsonb_build_object(
        'configured', true,
        'policy_published_at', p_policy_published_at,
        'program_not_before', v_not_before
    );
end;
$$;

revoke all on function public.email_program_gate_open() from public, anon, authenticated;
revoke all on function public.configure_email_policy_gate(timestamptz) from public, anon, authenticated;
grant execute on function public.email_program_gate_open() to service_role;
grant execute on function public.configure_email_policy_gate(timestamptz) to service_role;

-- The app reads and writes its own preferences directly; every topic is
-- materialised so a missing row reads as unsubscribed rather than unknown.
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
    select prompt_version into v_prompt_version from public.email_program_config where singleton;

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
    v_policy_version text;
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

    select policy_version into v_policy_version from public.email_program_config where singleton;
    if p_policy_version is distinct from v_policy_version then
        raise exception 'stale consent policy version' using errcode = '22023';
    end if;

    insert into public.email_preferences as current_preference (
        user_id, topic, status, policy_version, source,
        prompted_at, consented_at, unsubscribed_at, updated_at
    ) values (
        v_user_id, p_topic, p_status, v_policy_version, p_source,
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
        consented_at = case
            when excluded.status = 'subscribed' then now()
            else current_preference.consented_at
        end,
        unsubscribed_at = case when excluded.status = 'unsubscribed' then now() end,
        updated_at = now()
    returning * into v_row;

    return jsonb_build_object(
        'topic', v_row.topic,
        'status', v_row.status,
        'policy_version', v_row.policy_version,
        'source', v_row.source,
        'prompted_at', v_row.prompted_at,
        'consented_at', v_row.consented_at,
        'unsubscribed_at', v_row.unsubscribed_at
    );
end;
$$;

create or replace function public.mark_email_consent_prompt_seen(
    p_prompt_version text,
    p_source text default 'onboarding_prompt'
)
returns jsonb
language plpgsql
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
    if p_source not in ('onboarding_prompt', 'existing_user_prompt') then
        raise exception 'unsupported prompt source' using errcode = '22023';
    end if;
    select prompt_version into v_prompt_version from public.email_program_config where singleton;
    if p_prompt_version is distinct from v_prompt_version then
        raise exception 'stale consent prompt version' using errcode = '22023';
    end if;

    insert into public.email_consent_prompts (user_id, prompt_version, source)
    values (v_user_id, v_prompt_version, p_source)
    on conflict (user_id, prompt_version) do nothing;

    return jsonb_build_object('seen', true, 'prompt_version', v_prompt_version);
end;
$$;

revoke all on function public.get_email_preferences() from public, anon;
revoke all on function public.set_email_preference(text, text, text, text) from public, anon;
revoke all on function public.mark_email_consent_prompt_seen(text, text) from public, anon;
grant execute on function public.get_email_preferences() to authenticated;
grant execute on function public.set_email_preference(text, text, text, text) to authenticated;
grant execute on function public.mark_email_consent_prompt_seen(text, text) to authenticated;

-- Supabase stays authoritative; Resend is a mirror. Every preference change
-- queues one sync row per topic, and the queue is drained only after the gate.
create or replace function public.queue_resend_contact_sync()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_email text;
begin
    select lower(trim(email)) into v_email from auth.users where id = new.user_id;
    if coalesce(v_email, '') = '' then
        return new;
    end if;

    insert into public.resend_contact_sync as sync (
        user_id, email, topic, desired_status, policy_version, status, available_at, updated_at
    ) values (
        new.user_id, v_email, new.topic, new.status, new.policy_version, 'queued', now(), now()
    )
    on conflict (user_id, topic) do update set
        email = excluded.email,
        desired_status = excluded.desired_status,
        policy_version = excluded.policy_version,
        status = 'queued',
        attempts = 0,
        available_at = now(),
        last_error = null,
        updated_at = now()
    where sync.desired_status is distinct from excluded.desired_status
       or sync.status <> 'synced';
    return new;
end;
$$;

drop trigger if exists queue_resend_contact_sync on public.email_preferences;
create trigger queue_resend_contact_sync
    after insert or update of status on public.email_preferences
    for each row execute function public.queue_resend_contact_sync();

create or replace function public.claim_resend_contact_sync(p_limit integer default 20)
returns setof public.resend_contact_sync
language plpgsql
security definer
set search_path = ''
as $$
begin
    if not public.email_program_gate_open() then
        return;
    end if;
    return query
    with selected as (
        select id from public.resend_contact_sync
         where status = 'queued'
           and available_at <= now()
         order by available_at, updated_at
         limit greatest(1, least(coalesce(p_limit, 20), 100))
         for update skip locked
    )
    update public.resend_contact_sync sync
       set status = 'syncing',
           attempts = sync.attempts + 1,
           updated_at = now()
      from selected
     where sync.id = selected.id
    returning sync.*;
end;
$$;

-- Re-read the authoritative preference right before the provider call: a person
-- who changed their mind while the row sat in the queue wins.
create or replace function public.resend_contact_sync_guard(
    p_id uuid,
    p_desired_status text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
          from public.resend_contact_sync sync
          join public.email_preferences preference
            on preference.user_id = sync.user_id and preference.topic = sync.topic
         where sync.id = p_id
           and sync.desired_status = p_desired_status
           and preference.status = p_desired_status
    );
$$;

create or replace function public.complete_resend_contact_sync(
    p_id uuid,
    p_error text,
    p_retryable boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.resend_contact_sync
       set status = case
               when p_error is null then 'synced'
               when coalesce(p_retryable, false) and attempts < 8 then 'queued'
               else 'failed'
           end,
           available_at = case
               when p_error is not null and coalesce(p_retryable, false)
               then now() + (interval '2 minutes' * attempts)
               else available_at
           end,
           last_error = p_error,
           updated_at = now()
     where id = p_id;
end;
$$;

create or replace function public.queue_resend_contact_deletion(p_email text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_email text := lower(trim(p_email));
    v_id uuid;
begin
    if coalesce(v_email, '') = '' then
        return null;
    end if;
    insert into public.resend_contact_deletions as deletion (
        email, email_hash, status, available_at, updated_at
    ) values (
        v_email, encode(extensions.digest(v_email, 'sha256'), 'hex'), 'queued', now(), now()
    )
    on conflict (email_hash) do update set
        email = excluded.email,
        status = 'queued',
        attempts = 0,
        available_at = now(),
        last_error = null,
        updated_at = now()
    returning deletion.id into v_id;

    -- Erasure also suppresses: a re-signup with the same address must not
    -- inherit consent, and a late provider event must not resurrect it.
    insert into public.email_suppressions (email, scope, reason, source)
    values (v_email, 'all_email', 'account_deletion', 'account_deletion')
    on conflict (email, scope) do update set
        reason = 'account_deletion',
        source = 'account_deletion',
        updated_at = now();
    return v_id;
end;
$$;

create or replace function public.queue_resend_contact_deletion_on_account_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform public.queue_resend_contact_deletion(old.email);
    return old;
end;
$$;

drop trigger if exists queue_resend_contact_deletion_on_account_delete on auth.users;
create trigger queue_resend_contact_deletion_on_account_delete
    before delete on auth.users
    for each row execute function public.queue_resend_contact_deletion_on_account_delete();

create or replace function public.claim_resend_contact_deletions(p_limit integer default 20)
returns setof public.resend_contact_deletions
language plpgsql
security definer
set search_path = ''
as $$
begin
    return query
    with selected as (
        select id from public.resend_contact_deletions
         where status = 'queued'
           and available_at <= now()
         order by available_at, updated_at
         limit greatest(1, least(coalesce(p_limit, 20), 100))
         for update skip locked
    )
    update public.resend_contact_deletions deletion
       set status = 'deleting',
           attempts = deletion.attempts + 1,
           updated_at = now()
      from selected
     where deletion.id = selected.id
    returning deletion.*;
end;
$$;

create or replace function public.complete_resend_contact_deletion(
    p_id uuid,
    p_deleted boolean,
    p_error text,
    p_retryable boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.resend_contact_deletions
       set status = case
               when coalesce(p_deleted, false) then 'deleted'
               when coalesce(p_retryable, false) and attempts < 8 then 'queued'
               else 'failed'
           end,
           -- The address is only dropped once the provider confirms; until then
           -- the job still needs something to delete.
           email = case when coalesce(p_deleted, false) then null else email end,
           available_at = case
               when not coalesce(p_deleted, false) and coalesce(p_retryable, false)
               then now() + (interval '5 minutes' * attempts)
               else available_at
           end,
           last_error = p_error,
           updated_at = now()
     where id = p_id;
end;
$$;

create or replace function public.issue_email_preference_token(p_user_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_token text;
begin
    if not exists (select 1 from auth.users where id = p_user_id) then
        return null;
    end if;
    v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
    insert into public.email_preference_tokens (user_id, token_hash, expires_at)
    values (p_user_id, encode(extensions.digest(v_token, 'sha256'), 'hex'), now() + interval '1 year');
    return v_token;
end;
$$;

create or replace function public.resolve_email_preference_token(p_token text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid;
begin
    if p_token !~ '^[0-9a-f]{64}$' then
        return null;
    end if;
    update public.email_preference_tokens
       set last_used_at = now()
     where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
       and expires_at > now()
    returning user_id into v_user_id;
    return v_user_id;
end;
$$;

create or replace function public.public_email_preferences(p_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
    select jsonb_build_object(
        'preferences', (
            select jsonb_object_agg(topics.topic, coalesce(preference.status, 'unsubscribed'))
            from (values
                ('product_updates', 1),
                ('lifecycle_guidance', 2),
                ('founder_research', 3)
            ) as topics(topic, position)
            left join public.email_preferences preference
              on preference.user_id = p_user_id and preference.topic = topics.topic
        ),
        'policy_version', (select policy_version from public.email_program_config where singleton)
    );
$$;

create or replace function public.set_public_email_preferences(
    p_user_id uuid,
    p_preferences jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_topic text;
    v_status text;
    v_policy_version text;
begin
    if p_user_id is null or jsonb_typeof(p_preferences) <> 'object' then
        raise exception 'invalid email preference request' using errcode = '22023';
    end if;
    if exists (
        select 1 from jsonb_object_keys(p_preferences) key
         where key not in ('product_updates', 'lifecycle_guidance', 'founder_research')
    ) then
        raise exception 'unsupported email topic' using errcode = '22023';
    end if;

    select policy_version into v_policy_version from public.email_program_config where singleton;

    foreach v_topic in array array['product_updates', 'lifecycle_guidance', 'founder_research'] loop
        if p_preferences ? v_topic then
            v_status := p_preferences ->> v_topic;
            if v_status not in ('subscribed', 'unsubscribed') then
                raise exception 'unsupported email status' using errcode = '22023';
            end if;
            insert into public.email_preferences as current_preference (
                user_id, topic, status, policy_version, source,
                consented_at, unsubscribed_at, updated_at
            ) values (
                p_user_id, v_topic, v_status, v_policy_version, 'web_preferences',
                case when v_status = 'subscribed' then now() end,
                case when v_status = 'unsubscribed' then now() end,
                now()
            )
            on conflict (user_id, topic) do update set
                status = excluded.status,
                policy_version = excluded.policy_version,
                source = excluded.source,
                consented_at = case
                    when excluded.status = 'subscribed' then now()
                    else current_preference.consented_at
                end,
                unsubscribed_at = case when excluded.status = 'unsubscribed' then now() end,
                updated_at = now();
        end if;
    end loop;
    return public.public_email_preferences(p_user_id);
end;
$$;

revoke all on function public.queue_resend_contact_sync() from public, anon, authenticated;
revoke all on function public.claim_resend_contact_sync(integer) from public, anon, authenticated;
revoke all on function public.resend_contact_sync_guard(uuid, text) from public, anon, authenticated;
revoke all on function public.complete_resend_contact_sync(uuid, text, boolean) from public, anon, authenticated;
revoke all on function public.queue_resend_contact_deletion(text) from public, anon, authenticated;
revoke all on function public.queue_resend_contact_deletion_on_account_delete() from public, anon, authenticated;
revoke all on function public.claim_resend_contact_deletions(integer) from public, anon, authenticated;
revoke all on function public.complete_resend_contact_deletion(uuid, boolean, text, boolean) from public, anon, authenticated;
revoke all on function public.issue_email_preference_token(uuid) from public, anon, authenticated;
revoke all on function public.resolve_email_preference_token(text) from public, anon, authenticated;
revoke all on function public.public_email_preferences(uuid) from public, anon, authenticated;
revoke all on function public.set_public_email_preferences(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.queue_resend_contact_sync() to service_role;
grant execute on function public.claim_resend_contact_sync(integer) to service_role;
grant execute on function public.resend_contact_sync_guard(uuid, text) to service_role;
grant execute on function public.complete_resend_contact_sync(uuid, text, boolean) to service_role;
grant execute on function public.queue_resend_contact_deletion(text) to service_role;
grant execute on function public.queue_resend_contact_deletion_on_account_delete() to service_role;
grant execute on function public.claim_resend_contact_deletions(integer) to service_role;
grant execute on function public.complete_resend_contact_deletion(uuid, boolean, text, boolean) to service_role;
grant execute on function public.issue_email_preference_token(uuid) to service_role;
grant execute on function public.resolve_email_preference_token(text) to service_role;
grant execute on function public.public_email_preferences(uuid) to service_role;
grant execute on function public.set_public_email_preferences(uuid, jsonb) to service_role;

-- Billing history for cohorts. Recorded from the subscription writer so it is
-- exactly as ordered and idempotent as the write that caused it.
create or replace function public.capture_email_lifecycle_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_source text := case
        when new.last_paddle_event_id is null
             or new.last_paddle_event_id = 'migration-watermark'
             or new.last_paddle_event_id like 'legacy:%'
        then 'migration_backfill'
        else 'paddle_webhook'
    end;
    v_billing_cycle text;
begin
    if new.converted_at is not null
       and (tg_op = 'INSERT' or old.converted_at is null) then
        insert into public.email_lifecycle_events (
            user_id, event, occurred_at, source, source_event_id, dedupe_key
        ) values (
            new.user_id, 'paid_converted', new.converted_at, v_source,
            new.last_paddle_event_id, 'paid_converted:' || new.user_id::text
        ) on conflict (dedupe_key) do nothing;
    end if;

    select billing_cycle into v_billing_cycle
      from public.plan_prices where paddle_price_id = new.paddle_price_id;
    if v_billing_cycle = 'yearly' and new.status in ('active', 'past_due') then
        insert into public.email_lifecycle_events (
            user_id, event, occurred_at, source, source_event_id, dedupe_key
        ) values (
            new.user_id, 'yearly_entered', coalesce(new.current_period_start, now()), v_source,
            new.last_paddle_event_id, 'yearly_entered:' || new.user_id::text
        ) on conflict (dedupe_key) do nothing;
    end if;

    if new.status = 'canceled' and (tg_op = 'INSERT' or old.status is distinct from 'canceled') then
        insert into public.email_lifecycle_events (
            user_id, event, occurred_at, source, source_event_id, dedupe_key,
            metadata
        ) values (
            new.user_id, 'subscription_canceled', now(), v_source,
            new.last_paddle_event_id,
            'subscription_canceled:' || new.user_id::text || ':' || to_char(now(), 'YYYYMMDD'),
            jsonb_build_object('plan', new.plan)
        ) on conflict (dedupe_key) do nothing;
    end if;
    return new;
end;
$$;

drop trigger if exists capture_email_lifecycle_event on public.subscriptions;
create trigger capture_email_lifecycle_event
    after insert or update on public.subscriptions
    for each row execute function public.capture_email_lifecycle_event();

insert into public.email_lifecycle_events (
    user_id, event, occurred_at, source, dedupe_key
)
select user_id, 'paid_converted', converted_at, 'migration_backfill',
       'paid_converted:' || user_id::text
  from public.subscriptions
 where converted_at is not null
on conflict (dedupe_key) do nothing;

insert into public.email_lifecycle_events (
    user_id, event, occurred_at, source, dedupe_key
)
select s.user_id, 'yearly_entered', coalesce(s.current_period_start, s.converted_at, s.updated_at),
       'migration_backfill', 'yearly_entered:' || s.user_id::text
  from public.subscriptions s
  join public.plan_prices p on p.paddle_price_id = s.paddle_price_id
 where p.billing_cycle = 'yearly'
   and s.status in ('active', 'past_due')
on conflict (dedupe_key) do nothing;

revoke all on function public.capture_email_lifecycle_event() from public, anon, authenticated;
grant execute on function public.capture_email_lifecycle_event() to service_role;
