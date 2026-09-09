-- Fixes from an independent adversarial review of the briefing vertical
-- slice. Two are severe enough to be worth calling out specifically:
--
-- 1. The tier-3 attendee-overlap guard counted MATCHING SPEAKER ROWS, not
--    distinct matched tokens. A diarizer that splits one physical speaker
--    across two slots (e.g. {"1":"Vlad","2":"Vlad K"} -- a known ASR/
--    diarization failure mode, and this product's own transcription) let a
--    single real shared person satisfy the ">= 2 distinct people" guard this
--    tier exists to enforce -- reproducing the exact class of bug ("wrong
--    meeting attached") that got the previous version of this feature
--    reverted, just through a different trigger.
-- 2. `briefing_items` never recorded which meeting a briefing was actually
--    about (`target_node_id` was left null). The client had no choice but to
--    attribute the briefing text using the OLD, still-unfixed Swift heuristic
--    (`TodayBrief.lastSession`, unchanged) -- an independent matcher that can
--    legitimately disagree with the new one, which reintroduces the same
--    failure mode at the render layer even when the new linker itself
--    behaved correctly.
--
-- Also fixed: unbounded LLM regeneration (calendar-sync fix, separate diff),
-- and `evidence_refs.quote` holding an entire meeting body instead of an
-- excerpt.

create or replace function public.link_prior_meeting_for_calendar_source_object(p_calendar_source_object_id uuid)
    returns uuid
    language plpgsql
    set search_path = ''
as $$
declare
    v_cal_so           public.source_objects;
    v_ce               public.calendar_events;
    v_room_key         text;
    v_cal_node_id      uuid;
    v_meeting_node_id  uuid;
    v_meeting          record;
    v_edge_id          uuid;
    v_relation         text;
    v_confidence       numeric;
    v_resolver         text;
    v_attendee_tokens  text[];
begin
    select * into v_cal_so from public.source_objects where id = p_calendar_source_object_id;
    if v_cal_so.id is null or v_cal_so.object_type not like '%/event' then
        return null;
    end if;

    select * into v_ce from public.calendar_events
    where user_id = v_cal_so.user_id
      and (external_event_id = v_cal_so.external_id or id::text = v_cal_so.external_id)
    order by created_at desc
    limit 1;

    v_room_key := public.conference_room_key(v_ce.conference_url);

    insert into public.context_nodes (user_id, node_type, source_object_id, title, occurred_at)
    values (v_cal_so.user_id, 'calendar_event', v_cal_so.id, v_cal_so.title, v_cal_so.occurred_at)
    on conflict (source_object_id) do update set title = excluded.title, occurred_at = excluded.occurred_at, updated_at = now()
    returning id into v_cal_node_id;

    if v_ce.ical_uid is not null then
        select m.* into v_meeting from public.meetings m
        where m.user_id = v_cal_so.user_id and m.ical_uid = v_ce.ical_uid
          and m.deleted_at is null and m.merged_into is null
          and m.started_at < v_cal_so.occurred_at
        order by m.started_at desc limit 1;
        if v_meeting.id is not null then
            v_relation := 'same_event'; v_confidence := 1.0; v_resolver := 'ical_uid';
        end if;
    end if;

    if v_meeting.id is null and v_room_key is not null then
        select m.* into v_meeting from public.meetings m
        where m.user_id = v_cal_so.user_id and m.room_key = v_room_key
          and m.deleted_at is null and m.merged_into is null
          and m.started_at < v_cal_so.occurred_at
        order by m.started_at desc limit 1;
        if v_meeting.id is not null then
            v_relation := 'same_event'; v_confidence := 0.95; v_resolver := 'room_key';
        end if;
    end if;

    -- Tier 3, fixed: `count(distinct ...)` over the matched TOKEN, not over
    -- speaker rows -- two diarized slots that reduce to the same token
    -- ("vlad" from both "Vlad" and "Vlad K") now count as one shared person,
    -- not two.
    if v_meeting.id is null and v_ce.attendees is not null then
        select array_agg(distinct lower(split_part(a ->> 'email', '@', 1)))
          into v_attendee_tokens
          from jsonb_array_elements(v_ce.attendees) a
          where length(split_part(a ->> 'email', '@', 1)) >= 3;

        if v_attendee_tokens is not null and array_length(v_attendee_tokens, 1) > 0 then
            select m.* into v_meeting from public.meetings m
            where m.user_id = v_cal_so.user_id
              and m.deleted_at is null and m.merged_into is null
              and m.started_at < v_cal_so.occurred_at
              and (
                  select count(distinct lower(split_part(sn.value, ' ', 1)))
                  from jsonb_each_text(coalesce(m.speaker_names, '{}'::jsonb)) sn
                  where lower(split_part(sn.value, ' ', 1)) = any (v_attendee_tokens)
              ) >= 2
            order by m.started_at desc
            limit 1;
            if v_meeting.id is not null then
                v_relation := 'discussed'; v_confidence := 0.75; v_resolver := 'attendee_overlap_v2';
            end if;
        end if;
    end if;

    if v_meeting.id is null then
        return null;
    end if;

    select cn.id into v_meeting_node_id
    from public.context_nodes cn
    join public.source_objects so on so.id = cn.source_object_id
    where so.object_type = 'nod/meeting' and so.external_id = v_meeting.id::text and so.connection_id is null;

    if v_meeting_node_id is null then
        insert into public.context_nodes (user_id, node_type, source_object_id, title, occurred_at)
        select so.user_id, 'meeting', so.id, so.title, so.occurred_at
        from public.source_objects so
        where so.object_type = 'nod/meeting' and so.external_id = v_meeting.id::text and so.connection_id is null
        on conflict (source_object_id) do update set updated_at = now()
        returning id into v_meeting_node_id;
    end if;

    if v_meeting_node_id is null then
        return null;
    end if;

    insert into public.context_edges (user_id, from_node_id, to_node_id, relation, confidence, resolver, valid_from)
    values (v_cal_so.user_id, v_cal_node_id, v_meeting_node_id, v_relation, v_confidence, v_resolver, now())
    on conflict (from_node_id, to_node_id, relation, resolver) where valid_to is null
        do update set confidence = excluded.confidence
    returning id into v_edge_id;

    return v_edge_id;
end;
$$;

-- `quote` is an excerpt for a citation, not a body dump; truncated to 800
-- chars. `meeting_id` added to the output so the caller can attribute the
-- eventual briefing to the SAME meeting it was written about, instead of
-- re-deriving "which meeting was this" through a second, independent path.
create or replace function public.prepare_upcoming_meeting_briefing_input(p_context_edge_id uuid)
    returns jsonb
    language plpgsql
    set search_path = ''
as $$
declare
    v_edge          public.context_edges;
    v_meeting_so    public.source_objects;
    v_meeting_id    uuid;
    v_done          integer;
    v_open          integer;
    v_evidence_id   uuid;
begin
    select * into v_edge from public.context_edges where id = p_context_edge_id;
    if v_edge.id is null then
        return null;
    end if;

    select so.* into v_meeting_so
    from public.context_nodes cn
    join public.source_objects so on so.id = cn.source_object_id
    where cn.id = v_edge.to_node_id;

    if v_meeting_so.id is null then
        return null;
    end if;
    v_meeting_id := v_meeting_so.external_id::uuid;

    select
        count(*) filter (where done),
        count(*) filter (where not done)
    into v_done, v_open
    from public.action_items
    where meeting_id = v_meeting_id and kind = 'action' and status = 'confirmed' and deleted_at is null;

    insert into public.evidence_refs (user_id, source_object_id, native_table, native_id, locator, quote, observed_at)
    values (
        v_edge.user_id, v_meeting_so.id, 'meetings', v_meeting_id,
        jsonb_build_object('kind', 'meeting_summary'), left(v_meeting_so.body, 800), v_meeting_so.occurred_at
    )
    returning id into v_evidence_id;

    return jsonb_build_object(
        'calendar_node_id', v_edge.from_node_id,
        'meeting_node_id', v_edge.to_node_id,
        'meeting_id', v_meeting_id,
        'meeting_title', v_meeting_so.title,
        'meeting_summary', v_meeting_so.body,
        'meeting_occurred_at', v_meeting_so.occurred_at,
        'actions_done', coalesce(v_done, 0),
        'actions_open', coalesce(v_open, 0),
        'match_relation', v_edge.relation,
        'match_confidence', v_edge.confidence,
        'evidence_ref_id', v_evidence_id
    );
end;
$$;

-- `p_meeting_node_id` is now stored on the briefing item, so a reader can
-- resolve exactly which meeting this text is about without going back
-- through a different, independently-fallible matcher.
create or replace function public.upsert_upcoming_meeting_briefing(
    p_calendar_node_id uuid,
    p_meeting_node_id uuid,
    p_headline text,
    p_summary text,
    p_confidence numeric,
    p_generator_version text,
    p_evidence_ref_id uuid
)
    returns uuid
    language plpgsql
    set search_path = ''
as $$
declare
    v_user_id uuid;
    v_briefing_id uuid;
    v_item_id uuid;
begin
    select user_id into v_user_id from public.context_nodes where id = p_calendar_node_id;
    if v_user_id is null then
        return null;
    end if;

    delete from public.briefings
    where user_id = v_user_id and briefing_type = 'upcoming_meeting' and target_node_id = p_calendar_node_id;

    insert into public.briefings (
        user_id, briefing_type, target_node_id, status, headline, summary,
        confidence, input_watermark, generator_version, generated_at
    )
    values (
        v_user_id, 'upcoming_meeting', p_calendar_node_id, 'ready', p_headline, p_summary,
        p_confidence, now(), p_generator_version, now()
    )
    returning id into v_briefing_id;

    insert into public.briefing_items (briefing_id, item_type, position, title, body, target_node_id, confidence)
    values (v_briefing_id, 'change', 0, p_headline, p_summary, p_meeting_node_id, p_confidence)
    returning id into v_item_id;

    if p_evidence_ref_id is not null then
        insert into public.briefing_item_evidence (briefing_item_id, evidence_ref_id)
        values (v_item_id, p_evidence_ref_id);
    end if;

    return v_briefing_id;
end;
$$;

-- The client's read now also resolves the SAME meeting the summary is about
-- (via `briefing_items.target_node_id`, not the old attendee-name heuristic)
-- so "From <title>" and "Open last session" can never point at a different
-- meeting than the one the sentence describes.
drop function if exists public.get_upcoming_meeting_briefing(text);
create function public.get_upcoming_meeting_briefing(p_ical_uid text)
    returns table (headline text, summary text, confidence numeric, meeting_id uuid, meeting_title text, meeting_occurred_at timestamptz)
    language sql
    stable
    set search_path = ''
as $$
    select
        b.headline, b.summary, b.confidence,
        meeting_so.external_id::uuid, meeting_so.title, meeting_so.occurred_at
    from public.calendar_events ce
    join public.source_objects so
        on so.object_type = ce.provider || '/event'
        and so.external_id = coalesce(ce.external_event_id, ce.id::text)
        and so.connection_id is null
    join public.context_nodes cn on cn.source_object_id = so.id
    join public.briefings b
        on b.target_node_id = cn.id
        and b.briefing_type = 'upcoming_meeting'
        and b.status = 'ready'
    join public.briefing_items bi on bi.briefing_id = b.id
    join public.context_nodes meeting_cn on meeting_cn.id = bi.target_node_id
    join public.source_objects meeting_so on meeting_so.id = meeting_cn.source_object_id
    where ce.ical_uid = p_ical_uid
    limit 1;
$$;

revoke all on function public.get_upcoming_meeting_briefing(text) from public, anon;
grant execute on function public.get_upcoming_meeting_briefing(text) to authenticated;

-- Whether a target already has a fresh, ready briefing -- calendar-sync
-- checks this BEFORE running the linker or calling the model, so a person
-- with the app open all day doesn't pay for a fresh completion every
-- 15-minute sync floor for an answer that hasn't changed. Keyed on the
-- calendar event's own source object (not the context node, which may not
-- exist yet on a first run -- no node correctly means no briefing either).
-- 24h is a simple fixed staleness window, not configurable -- there is no
-- product signal yet for what "changed enough to regenerate" means.
create function public.has_fresh_upcoming_meeting_briefing(p_calendar_source_object_id uuid)
    returns boolean
    language sql
    stable
    set search_path = ''
as $$
    select exists (
        select 1
        from public.context_nodes cn
        join public.briefings b on b.target_node_id = cn.id
        where cn.source_object_id = p_calendar_source_object_id
          and b.briefing_type = 'upcoming_meeting'
          and b.status = 'ready'
          and b.generated_at > now() - interval '24 hours'
    );
$$;

revoke all on function public.has_fresh_upcoming_meeting_briefing(uuid) from public, anon, authenticated;
grant execute on function public.has_fresh_upcoming_meeting_briefing(uuid) to service_role;
