-- A session to open before the first one.
--
-- A new account lands on an empty list and a checklist, which says what Nod
-- will do and shows none of it. This seeds one real session — notes, action
-- items, transcript — so the product can be read, ticked off and asked a
-- question before anybody has recorded anything.
--
-- Real rows, deliberately. Every surface a new person might wander into (the
-- list, the detail view, the action-item checklist, Ask, the per-session chat)
-- reads from these tables, and the alternative is teaching four stores to mix a
-- fake row into real results — which is what `DemoMode` does in the client, and
-- why it is compiled out of Release.
--
-- Written, not recorded, and it says so in its own first line. A fabricated
-- transcript presented as a recording would be the one thing this must not do.

-- ── Where a session came from ───────────────────────────────────────────────

-- A column rather than a `kind`. `SessionKind` is a non-optional Swift enum with
-- no unknown-value fallback, so a released client meeting `kind = 'welcome'`
-- fails to decode the whole meeting row. An unknown *column* is ignored by every
-- client, released or not, which makes this an expand step with no contract.
--
-- Null is the ordinary case: a session somebody recorded.
alter table public.meetings
    add column if not exists origin text;

comment on column public.meetings.origin is
    'Non-null when Nod created the session rather than the user recording it. '
    '''welcome'' is the sample seeded at signup. Exclude these from any count of '
    'what a person has actually recorded.';

-- ── The sample ──────────────────────────────────────────────────────────────

-- Idempotent, and narrower than that: it seeds only into an account with no
-- sessions at all. Two Macs signing in on the same morning both call this, and
-- somebody who deleted the sample is not given it back.
create function public.seed_welcome_session()
    returns uuid
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_user uuid := auth.uid();
    v_name text;
    v_meeting uuid;
    v_started timestamptz;
    v_sections jsonb;
    v_actions jsonb;
    v_summary text;
    v_line record;
begin
    -- Its own authorization check. The grant below is the second line of
    -- defence, never the first.
    if v_user is null then
        raise exception 'not_authenticated' using errcode = '28000';
    end if;

    -- Any session at all, including one they deleted. Coming back to an empty
    -- list after clearing it out is a choice, not a state to repair.
    if exists (select 1 from public.meetings where user_id = v_user) then
        return null;
    end if;

    v_name := coalesce(public._display_name(v_user), 'you');
    v_started := now() - interval '7 minutes';
    v_meeting := gen_random_uuid();

    v_sections := jsonb_build_array(
        jsonb_build_object(
            'title', 'What this is',
            'bullets', jsonb_build_array(
                jsonb_build_object('text',
                    'A sample session, written by Nod rather than recorded — so there is something to open before your first real one.'),
                jsonb_build_object('text',
                    'It behaves like any other session: the notes are editable, the action items tick off, and Ask answers out of the transcript.')
            )
        ),
        jsonb_build_object(
            'title', 'What Nod does with a session',
            'bullets', jsonb_build_array(
                jsonb_build_object('text',
                    'Captures both sides — your microphone and your Mac''s own audio — so a call, a room, or a voice note all arrive the same way.'),
                jsonb_build_object('text',
                    'Writes the notes when you stop, and pulls out what anybody committed to as the action items above.'),
                jsonb_build_object('text',
                    'Keeps it searchable: ask weeks later and the answer comes back naming the session it came from.')
            )
        )
    );

    -- Rendered from the same sections the JSON carries, rather than written
    -- twice: `summary` is what the detail view draws, `recap_json` is what the
    -- app re-serializes, and a fixture that spelled them separately would be
    -- the one recap in the product where they disagree.
    select string_agg(block, E'\n\n' order by ord)
      into v_summary
      from (
        select s.ord,
               '**' || (s.section->>'title') || '**' || E'\n' ||
               (select string_agg('- ' || (b->>'text'), E'\n')
                  from jsonb_array_elements(s.section->'bullets') b)
               as block
          from jsonb_array_elements(v_sections) with ordinality as s(section, ord)
      ) blocks;

    v_actions := jsonb_build_array(
        jsonb_build_object('text', 'Create your Nod account', 'done', true),
        jsonb_build_object('text', 'Check this one off — that is how every action item works', 'done', false),
        jsonb_build_object('text', 'Let Nod hear both sides: allow the microphone and screen recording', 'done', false),
        jsonb_build_object('text', 'Connect a calendar, so sessions arrive named and with who was in them', 'done', false),
        jsonb_build_object('text', 'Record your first real session — a meeting, a call, or a voice note', 'done', false)
    );

    insert into public.meetings (
        id, user_id, started_at, ended_at, title, summary, recap_json, kind, language, origin
    ) values (
        v_meeting,
        v_user,
        v_started,
        v_started + interval '6 minutes',
        v_name || ' <> Nod',
        v_summary,
        jsonb_build_object('sections', v_sections, 'action_items', jsonb_build_array()),
        'meeting',
        'en',
        'welcome'
    );

    -- `them` is Nod's side, `me` is theirs — the same two streams a recorded
    -- call produces, so the transcript tab and every prompt that reads
    -- "[Me]"/"[Them]" need no special case for this session.
    for v_line in
        select *
          from (values
            (0, 'them', 'Hi ' || v_name || ' — this one is written rather than recorded. It is here so you have a session to open before your first real one.'),
            (1, 'me',   'Fair enough. What happens when I actually record something?'),
            (2, 'them', 'Nod captures both sides: your microphone, and whatever is playing through your Mac. A video call, somebody across the table, a voice note to yourself — they all land here the same way.'),
            (3, 'me',   'And then?'),
            (4, 'them', 'When you stop, Nod writes the notes you are reading now and pulls out whatever anybody committed to. Those become the action items above, and you tick them off as they get done.'),
            (5, 'me',   'What if I cannot remember which meeting something was decided in?'),
            (6, 'them', 'You do not have to. Ask Nod anything and it searches every session you have recorded, and tells you which one the answer came from.'),
            (7, 'me',   'Can I ask while a meeting is still running?'),
            (8, 'them', 'Yes — that is the Ask box in the notch at the top of your screen. It answers from what has been said so far. If you have connected Linear or Slack it can check those too: type @ to point the question at one.'),
            (9, 'me',   'What about the things I say I will do?'),
            (10, 'them', 'Nod follows those across sessions, so something you promised three weeks ago comes back before your next call with the same person.'),
            (11, 'me',  'Right. Where do I start?'),
            (12, 'them', 'The checklist above this transcript. Tick the first one off — that is the whole interaction.')
          ) as t(idx, source, text)
    loop
        insert into public.meeting_transcripts (meeting_id, user_id, source, text, ts, idx)
        values (
            v_meeting,
            v_user,
            v_line.source,
            v_line.text,
            v_started + (v_line.idx * interval '25 seconds'),
            v_line.idx
        );
    end loop;

    insert into public.action_items (user_id, meeting_id, text, position, done, done_at, source)
    select
        v_user,
        v_meeting,
        a.value->>'text',
        (a.ordinality - 1)::integer,
        (a.value->>'done')::boolean,
        case when (a.value->>'done')::boolean then v_started else null end,
        'recap'
      from jsonb_array_elements(v_actions) with ordinality as a(value, ordinality);

    return v_meeting;
end;
$$;

-- Postgres grants EXECUTE to PUBLIC on every new function, and `anon` inherits
-- it — so the revoke names `public`, not just `anon`.
revoke all on function public.seed_welcome_session() from public, anon;
grant execute on function public.seed_welcome_session() to authenticated;
