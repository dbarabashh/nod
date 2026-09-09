-- Count what happens after the recording.
--
-- The allow-list measures capture, viewing and paying. Everything the product
-- became since — commitments moved, beats run, modes chosen, questions aimed,
-- sessions shared, calendars allowed, errors shown, the app reached by hotkey
-- or notch, updates taken — reports nothing. This adds the events for those,
-- one bounded `detail` word for the dimension each needs, and the outcomes
-- and reason codes they use.
--
-- It also repairs the four events accepted on 2026-08-30: the client sends
-- `provider` and the outcomes `empty`, `refused`, `enabled`, `disabled` and
-- `paused` with them, and this validator knew neither, so every one of those
-- rows was refused as `invalid_properties` — 70 of them on the develop branch,
-- and not a single `integration_connected` landed.
--
-- Still not accepted, and not to be added without reopening `privacy.md`
-- § 3.8: a question, an answer, a title, a name, a custom mode's name (it is
-- sent as `custom`), an email address, a window title.

create or replace function public._client_product_events()
returns text[]
language sql
immutable
set search_path = ''
as $$
    select array[
        'app_opened',
        'capture_start_requested',
        'capture_started',
        'capture_stopped',
        'capture_failed',
        'capture_discarded',
        'summary_viewed',
        'transcript_viewed',
        'action_items_viewed',
        'content_copied',
        'meeting_exported',
        'ai_action_completed',
        'paywall_viewed',
        'allowance_gate_viewed',
        'allowance_gate_action',
        'referral_nudge_viewed',
        'referral_link_shared',
        'email_consent_saved',
        'integration_connected',
        'integration_revoked',
        'lookup_routed',
        'tool_call_reviewed',
        'ambient_context_toggled',
        'action_item_acted',
        'beat_changed',
        'beat_report_opened',
        'mode_changed',
        'question_asked',
        'answer_source_opened',
        'meeting_shared',
        'share_revoked',
        'team_member_invited',
        'invite_accepted',
        'calendar_connected',
        'meeting_attendance_answered',
        'error_shown',
        'notch_opened',
        'hotkey_used',
        'app_session_ended',
        'update_install_clicked',
        'support_opened'
    ]::text[];
$$;

revoke all on function public._client_product_events() from public, anon, authenticated;
grant execute on function public._client_product_events() to service_role;

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
               'outcome', 'plan', 'billing', 'provider', 'detail'
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
           'persistence_failed', 'user_cancelled', 'authentication_failed', 'unknown',
           'summary_failed', 'sync_failed', 'integration_failed', 'credits_exhausted', 'search_failed'
       ))
       and (p_properties ->> 'surface' is null or p_properties ->> 'surface' in (
           'onboarding', 'capture', 'home', 'library', 'meeting_detail', 'ask', 'paywall',
           'settings', 'share', 'beats'
       ))
       and (p_properties ->> 'content_type' is null or p_properties ->> 'content_type' in (
           'summary', 'transcript', 'action_items', 'answer', 'meeting', 'markdown'
       ))
       and (p_properties ->> 'ai_feature' is null or p_properties ->> 'ai_feature' in (
           'catch_up', 'suggest_reply', 'key_points', 'follow_up', 'live_ask',
           'meeting_ask', 'knowledge_ask', 'recap', 'summary_regeneration'
       ))
       and (p_properties ->> 'outcome' is null or p_properties ->> 'outcome' in (
           'granted', 'declined', 'success', 'failure', 'cancelled', 'viewed',
           'empty', 'refused', 'enabled', 'disabled', 'paused',
           'done', 'reopened', 'delegated', 'asked', 'filed', 'auto_closed', 'created', 'deleted'
       ))
       and (p_properties ->> 'plan' is null or p_properties ->> 'plan' in (
           'trial', 'starter', 'pro', 'team', 'unknown'
       ))
       and (p_properties ->> 'billing' is null or p_properties ->> 'billing' in (
           'monthly', 'yearly', 'one_time', 'none', 'unknown'
       ))
       -- `IntegrationProvider.rawValue`, and nothing a person typed.
       and (p_properties ->> 'provider' is null or p_properties ->> 'provider' in (
           'linear', 'google-calendar', 'slack', 'github', 'jira', 'notion', 'asana', 'hubspot',
           'gmail', 'google-drive', 'google-ads', 'google-tasks'
       ))
       and (p_properties ->> 'detail' is null or p_properties ->> 'detail' in (
           -- a beat's cadence
           'daily', 'weekdays', 'weekly', 'monthly',
           -- a preset mode, or that it was not one
           'general', 'interview', 'sales_call', 'one_on_one', 'standup', 'custom',
           -- how a question was aimed
           'pinned', 'project', 'follow_up', 'open',
           -- who a share went to
           'link', 'team', 'organization',
           -- which hotkey
           'toggle_panel', 'ask_nod', 'hold_to_ask',
           -- how long the app stayed open
           'under_1m', '1_10m', '10_60m', 'over_1h',
           -- which support tile
           'bug', 'feature'
       ));
$$;

revoke all on function public._valid_product_event_properties(jsonb) from public, anon, authenticated;
