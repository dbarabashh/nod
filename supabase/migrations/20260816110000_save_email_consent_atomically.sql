-- One call for the whole consent card, so a rejected topic cannot leave a
-- half-recorded answer behind.
--
-- The prompt writes three topics and then marks itself seen. Doing that as four
-- separate round trips meant any refusal — a stale policy version from an older
-- build is the one we hit twice — aborted the sequence partway: the first topic
-- was already written, the rest were not, the prompt was never marked seen, and
-- the person was shown "couldn't save" over a card that had in fact changed one
-- of their choices. Consent that does not match the screen it was given on is
-- worse than no consent, and the card could never be dismissed.
--
-- A function body is a single transaction, so either every choice lands or none
-- does. The per-topic policy-version check is kept exactly as it was: it is what
-- stops a build recording consent under wording it never displayed.

create or replace function public.save_email_consent(
    p_choices jsonb,
    p_prompt_version text,
    p_source text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := auth.uid();
    v_prompt_version text;
    v_choice jsonb;
    v_topic text;
    v_status text;
    v_expected_policy_version text;
begin
    if v_user_id is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if p_source not in ('onboarding_prompt', 'existing_user_prompt') then
        raise exception 'unsupported prompt source' using errcode = '22023';
    end if;
    if jsonb_typeof(p_choices) is distinct from 'array' then
        raise exception 'choices must be an array' using errcode = '22023';
    end if;

    select prompt_version into v_prompt_version
      from public.email_program_config where singleton;
    if p_prompt_version is distinct from v_prompt_version then
        raise exception 'stale consent prompt version' using errcode = '22023';
    end if;

    for v_choice in select * from jsonb_array_elements(p_choices) loop
        v_topic := v_choice ->> 'topic';
        v_status := v_choice ->> 'status';

        if v_topic not in ('product_updates', 'lifecycle_guidance', 'founder_research')
           or v_status not in ('subscribed', 'unsubscribed') then
            raise exception 'unsupported email preference request' using errcode = '22023';
        end if;

        v_expected_policy_version := case
            when v_topic = 'lifecycle_guidance' then 'communications-v2'
            else 'communications-v1'
        end;
        if (v_choice ->> 'policy_version') is distinct from v_expected_policy_version then
            raise exception 'stale consent policy version' using errcode = '22023';
        end if;

        insert into public.email_preferences as current_preference (
            user_id, topic, status, policy_version, source,
            prompted_at, consented_at, unsubscribed_at, updated_at
        ) values (
            v_user_id, v_topic, v_status, v_expected_policy_version, p_source,
            now(),
            case when v_status = 'subscribed' then now() end,
            case when v_status = 'unsubscribed' then now() end,
            now()
        )
        on conflict (user_id, topic) do update set
            status = excluded.status,
            policy_version = excluded.policy_version,
            source = excluded.source,
            prompted_at = coalesce(excluded.prompted_at, current_preference.prompted_at),
            consented_at = case when excluded.status = 'subscribed' then now() else current_preference.consented_at end,
            unsubscribed_at = case when excluded.status = 'unsubscribed' then now() end,
            updated_at = now();
    end loop;

    insert into public.email_consent_prompts (user_id, prompt_version, source)
    values (v_user_id, v_prompt_version, p_source)
    on conflict (user_id, prompt_version) do nothing;

    return jsonb_build_object('saved', true, 'prompt_version', v_prompt_version);
end;
$$;

revoke all on function public.save_email_consent(jsonb, text, text) from public, anon;
grant execute on function public.save_email_consent(jsonb, text, text) to authenticated;
