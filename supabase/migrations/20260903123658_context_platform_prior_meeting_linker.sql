-- Deterministic prior-meeting linker (§9's matching order, tiers 1-3 only —
-- semantic/temporal-only tiers 4-5 are skipped for this slice; a calendar
-- event with no strong match simply gets no briefing, per the plan's own
-- rule: "If confidence is insufficient, fall back to a truthful calendar
-- card."
--
-- Tier 3 (attendee overlap) requires >= 2 shared tokens and lands as a
-- CANDIDATE edge (confidence 0.75, matching §7.3's 0.70-0.89 band) rather
-- than an auto edge — this repo's existing `TodayBrief.lastSession` accepts
-- a single shared first-name token with no lower bound on overlap count,
-- which is the likely cause of a synthesis feature attaching to the wrong
-- meeting entirely (reverted 2026-09-03). This function does not touch that
-- Swift code; it exists so the new briefing path does not repeat the same
-- mistake.
create function public.link_prior_meeting_for_calendar_source_object(p_calendar_source_object_id uuid)
    returns uuid
    language plpgsql
    set search_path = ''
as $$
declare
    v_cal_so           public.source_objects;
    v_ce               public.calendar_events;
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

    insert into public.context_nodes (user_id, node_type, source_object_id, title, occurred_at)
    values (v_cal_so.user_id, 'calendar_event', v_cal_so.id, v_cal_so.title, v_cal_so.occurred_at)
    on conflict (source_object_id) do update set title = excluded.title, occurred_at = excluded.occurred_at, updated_at = now()
    returning id into v_cal_node_id;

    -- Tier 1: exact ical_uid.
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

    -- Tier 2: exact conference room key.
    if v_meeting.id is null and v_ce.room_key is not null then
        select m.* into v_meeting from public.meetings m
        where m.user_id = v_cal_so.user_id and m.room_key = v_ce.room_key
          and m.deleted_at is null and m.merged_into is null
          and m.started_at < v_cal_so.occurred_at
        order by m.started_at desc limit 1;
        if v_meeting.id is not null then
            v_relation := 'same_event'; v_confidence := 0.95; v_resolver := 'room_key';
        end if;
    end if;

    -- Tier 3: attendee-token overlap, candidate confidence, >= 2 shared
    -- tokens required. Tokens come from the calendar attendees' email local
    -- parts (real identifiers) matched against meeting speaker display names
    -- (free text) — the only signal available on the meeting side today.
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
                  select count(*) from jsonb_each_text(coalesce(m.speaker_names, '{}'::jsonb)) sn
                  where lower(split_part(sn.value, ' ', 1)) = any (v_attendee_tokens)
              ) >= 2
            order by m.started_at desc
            limit 1;
            if v_meeting.id is not null then
                v_relation := 'discussed'; v_confidence := 0.75; v_resolver := 'attendee_overlap_v1';
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

    -- The meeting was never backfilled into the envelope (deleted/merged at
    -- backfill time) -- nothing to point a briefing at.
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

revoke all on function public.link_prior_meeting_for_calendar_source_object(uuid) from public, anon, authenticated;
grant execute on function public.link_prior_meeting_for_calendar_source_object(uuid) to service_role;

-- The evidence pack for one linked pair: what the prior meeting settled, and
-- how many of its actions are done since. Writes one `evidence_refs` row
-- pointing at the prior meeting's own source object -- the provenance for
-- every claim the eventual briefing text makes about "last time".
create function public.prepare_upcoming_meeting_briefing_input(p_context_edge_id uuid)
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
        jsonb_build_object('kind', 'meeting_summary'), v_meeting_so.body, v_meeting_so.occurred_at
    )
    returning id into v_evidence_id;

    return jsonb_build_object(
        'calendar_node_id', v_edge.from_node_id,
        'meeting_node_id', v_edge.to_node_id,
        'meeting_title', v_meeting_so.title,
        'meeting_summary', v_meeting_so.body,
        'actions_done', coalesce(v_done, 0),
        'actions_open', coalesce(v_open, 0),
        'match_relation', v_edge.relation,
        'match_confidence', v_edge.confidence,
        'evidence_ref_id', v_evidence_id
    );
end;
$$;

revoke all on function public.prepare_upcoming_meeting_briefing_input(uuid) from public, anon, authenticated;
grant execute on function public.prepare_upcoming_meeting_briefing_input(uuid) to service_role;

-- Writes (or replaces) the `upcoming_meeting` briefing itself, given the
-- generated text. Kept separate from the LLM call (which must happen in
-- Deno) so the write side stays pure SQL and testable without a model.
create function public.upsert_upcoming_meeting_briefing(
    p_calendar_node_id uuid,
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

    insert into public.briefing_items (briefing_id, item_type, position, title, body, confidence)
    values (v_briefing_id, 'change', 0, p_headline, p_summary, p_confidence)
    returning id into v_item_id;

    if p_evidence_ref_id is not null then
        insert into public.briefing_item_evidence (briefing_item_id, evidence_ref_id)
        values (v_item_id, p_evidence_ref_id);
    end if;

    return v_briefing_id;
end;
$$;

revoke all on function public.upsert_upcoming_meeting_briefing(uuid, text, text, numeric, text, uuid) from public, anon, authenticated;
grant execute on function public.upsert_upcoming_meeting_briefing(uuid, text, text, numeric, text, uuid) to service_role;
