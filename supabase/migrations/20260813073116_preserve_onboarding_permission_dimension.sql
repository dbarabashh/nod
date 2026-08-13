create or replace function public._valid_product_event_properties(p_properties jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
    select jsonb_typeof(coalesce(p_properties, '{}'::jsonb)) = 'object'
       and not exists (
           select 1
           from jsonb_object_keys(coalesce(p_properties, '{}'::jsonb)) key
           where key not in (
               'platform', 'app_version', 'session_kind', 'entry_point', 'stage',
               'permission', 'reason_code', 'surface', 'content_type', 'ai_feature',
               'outcome', 'plan', 'billing'
           )
       )
       and (p_properties ->> 'platform' is null or p_properties ->> 'platform' in ('macos', 'ios'))
       and (p_properties ->> 'app_version' is null or p_properties ->> 'app_version' ~ '^[0-9A-Za-z.+-]{1,32}$')
       and (p_properties ->> 'session_kind' is null or p_properties ->> 'session_kind' in (
           'meeting', 'voice_note', 'media', 'conversation', 'lecture', 'meetup', 'conference'
       ))
       and (p_properties ->> 'entry_point' is null or p_properties ->> 'entry_point' in (
           'app_launch', 'menu_bar', 'main_window', 'floating_panel', 'hotkey', 'deep_link',
           'home', 'library', 'quick_capture', 'live_activity', 'meeting_detail', 'ask', 'settings',
           'notch', 'email'
       ))
       and (p_properties ->> 'stage' is null or p_properties ->> 'stage' in (
           'welcome', 'profile', 'permissions', 'tutorial', 'consent', 'authentication',
           'entitlement', 'vad', 'audio', 'capture', 'transcription', 'persistence', 'finalization'
       ))
       and (p_properties ->> 'permission' is null or p_properties ->> 'permission' in (
           'microphone', 'screen_recording'
       ))
       and (p_properties ->> 'reason_code' is null or p_properties ->> 'reason_code' in (
           'permission_denied', 'entitlement_required', 'hours_exhausted', 'vad_unavailable',
           'audio_start_failed', 'interrupted', 'route_changed', 'transcription_failed',
           'persistence_failed', 'user_cancelled', 'authentication_failed', 'unknown'
       ))
       and (p_properties ->> 'surface' is null or p_properties ->> 'surface' in (
           'onboarding', 'capture', 'home', 'library', 'meeting_detail', 'ask', 'paywall',
           'settings', 'share'
       ))
       and (p_properties ->> 'content_type' is null or p_properties ->> 'content_type' in (
           'summary', 'transcript', 'action_items', 'answer', 'meeting', 'markdown'
       ))
       and (p_properties ->> 'ai_feature' is null or p_properties ->> 'ai_feature' in (
           'catch_up', 'suggest_reply', 'key_points', 'follow_up', 'live_ask',
           'meeting_ask', 'knowledge_ask', 'recap', 'summary_regeneration'
       ))
       and (p_properties ->> 'outcome' is null or p_properties ->> 'outcome' in (
           'granted', 'declined', 'success', 'failure', 'cancelled', 'viewed'
       ))
       and (p_properties ->> 'plan' is null or p_properties ->> 'plan' in (
           'trial', 'starter', 'pro', 'team', 'unknown'
       ))
       and (p_properties ->> 'billing' is null or p_properties ->> 'billing' in (
           'monthly', 'yearly', 'one_time', 'none', 'unknown'
       ));
$$;

revoke all on function public._valid_product_event_properties(jsonb) from public, anon, authenticated;

create or replace function public.record_onboarding_events(p_installation_id uuid, p_events jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := auth.uid();
    v_item jsonb;
    v_properties jsonb;
    v_accepted integer := 0;
    v_duplicates integer := 0;
    v_rejected integer := 0;
    v_inserted integer;
    v_platform text;
    v_event text;
    v_occurred_at timestamptz;
begin
    if p_installation_id is null or jsonb_typeof(p_events) <> 'array' or jsonb_array_length(p_events) > 25 then
        insert into public.product_event_rejections (user_id, installation_id, reason_code)
        values (v_user_id, p_installation_id, 'invalid_batch');
        return jsonb_build_object('accepted', 0, 'duplicates', 0, 'rejected', 1);
    end if;
    if v_user_id is null and (
        select count(*)
        from public.onboarding_events
        where installation_id = p_installation_id
          and created_at >= date_trunc('day', now())
    ) + jsonb_array_length(p_events) > 100 then
        insert into public.product_event_rejections (installation_id, platform, reason_code)
        values (p_installation_id, 'ios', 'rate_limited');
        return jsonb_build_object('accepted', 0, 'duplicates', 0, 'rejected', jsonb_array_length(p_events));
    end if;

    for v_item in select value from jsonb_array_elements(p_events)
    loop
        v_properties := coalesce(v_item -> 'properties', '{}'::jsonb);
        v_platform := v_item ->> 'platform';
        v_event := public._rejected_event_name(v_item ->> 'event');
        if coalesce(v_item ->> 'id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
           or coalesce(v_item ->> 'app_session_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
            insert into public.product_event_rejections (user_id, installation_id, platform, reason_code, event)
            values (v_user_id, p_installation_id, case when v_platform in ('macos', 'ios') then v_platform end, 'invalid_identifier', v_event);
            v_rejected := v_rejected + 1;
            continue;
        end if;
        if coalesce(v_platform, '') not in ('macos', 'ios')
           or (v_user_id is null and v_platform <> 'ios')
           or coalesce(v_item ->> 'event', '') not in (
               'step_shown', 'analytics_consent_resolved', 'onboarding_completed',
               'auth_started', 'auth_failed', 'profile_completed', 'profile_skipped',
               'permission_requested', 'permission_granted', 'permission_denied',
               'permission_pending_relaunch', 'permissions_skipped', 'relaunch_prompted',
               'relaunch_clicked', 'relaunch_failed'
           )
           or coalesce(v_item ->> 'app_version', '') !~ '^[0-9A-Za-z.+-]{1,32}$' then
            insert into public.product_event_rejections (user_id, installation_id, platform, reason_code, event)
            values (v_user_id, p_installation_id, case when v_platform in ('macos', 'ios') then v_platform end, 'invalid_event', v_event);
            v_rejected := v_rejected + 1;
            continue;
        end if;
        if not public._valid_product_event_properties(v_properties) then
            insert into public.product_event_rejections (user_id, installation_id, platform, reason_code, event)
            values (v_user_id, p_installation_id, v_platform, 'invalid_properties', v_event);
            v_rejected := v_rejected + 1;
            continue;
        end if;
        begin
            v_occurred_at := (v_item ->> 'occurred_at')::timestamptz;
        exception when others then
            v_occurred_at := null;
        end;
        if v_occurred_at is null
           or v_occurred_at < now() - interval '7 days'
           or v_occurred_at > now() + interval '5 minutes' then
            insert into public.product_event_rejections (user_id, installation_id, platform, reason_code, event)
            values (v_user_id, p_installation_id, v_platform, 'invalid_timestamp', v_event);
            v_rejected := v_rejected + 1;
            continue;
        end if;

        insert into public.onboarding_events (
            id, user_id, installation_id, app_session_id, occurred_at,
            event, step, detail, app_version, platform
        ) values (
            (v_item ->> 'id')::uuid,
            v_user_id,
            p_installation_id,
            (v_item ->> 'app_session_id')::uuid,
            v_occurred_at,
            v_item ->> 'event',
            v_properties ->> 'stage',
            coalesce(v_properties ->> 'permission', v_properties ->> 'reason_code', v_properties ->> 'outcome'),
            left(coalesce(nullif(v_item ->> 'app_version', ''), '0'), 32),
            v_platform
        ) on conflict (id) do nothing;
        get diagnostics v_inserted = row_count;
        if v_inserted = 1 then
            v_accepted := v_accepted + 1;
        else
            v_duplicates := v_duplicates + 1;
        end if;
    end loop;

    return jsonb_build_object(
        'accepted', v_accepted,
        'duplicates', v_duplicates,
        'rejected', v_rejected
    );
end;
$$;

revoke all on function public.record_onboarding_events(uuid, jsonb) from public;
grant execute on function public.record_onboarding_events(uuid, jsonb) to anon, authenticated;
