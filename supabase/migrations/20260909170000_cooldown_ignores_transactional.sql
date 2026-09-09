-- The optional-email cooldown must only count optional email.
--
-- `optional_email_cooldown_clear` looked at every outbox row regardless of
-- class, so any transactional send silenced optional email afterwards: 72 hours
-- for a trial-learning campaign, 14 days for everything else.
--
-- That was survivable while the only transactional emails were referral
-- notices. The welcome letter makes it fatal: it is queued at signup, so it
-- suppressed `trial-learning-day-1` outright (it qualifies at signup + 1 day,
-- inside the 72-hour window) and every activation campaign for the first 14
-- days of an account's life — silently, with no error and no outbox row.
--
-- The cadence rules this function enforces ("activation guidance at most once
-- per 14 days", "founder research at most once per 30 days") are about how much
-- optional email a person receives. A transactional notice they triggered
-- themselves is not part of that budget.

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
          join public.email_campaigns campaign
            on campaign.campaign_key = outbox.campaign_key
           and campaign.version = outbox.campaign_version
         where outbox.user_id = p_user_id
           and campaign.email_class <> 'transactional'
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

revoke all on function public.optional_email_cooldown_clear(uuid, text, text) from public, anon, authenticated;
grant execute on function public.optional_email_cooldown_clear(uuid, text, text) to service_role;
