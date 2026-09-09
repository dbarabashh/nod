-- The sample covers the two things it missed.
--
-- Ambient context and the keyboard shortcuts are the parts of Nod nobody finds
-- by clicking around: one is a switch in the sidebar whose consequences are not
-- written next to it, and the other leaves no trace in the interface at all.
-- The sample session is where somebody reads about the product, so they belong
-- in it.
--
-- The ambient-context wording is taken from `AboutNod`'s "Does Nod watch my
-- screen?" answer rather than written fresh. That copy is the reviewed one, it
-- is what the openers beside this session answer with, and privacy claims that
-- disagree between two surfaces are worse than a claim made once.
--
-- The shortcuts are the defaults in `HotkeyAction.defaultCombo` — ⌘⇧H for the
-- panel, ⌘⇧K for search. Both are rebindable in Settings › Shortcuts, which is
-- why the line says so rather than presenting them as fixed.

create or replace function public.seed_welcome_session()
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
    if v_user is null then
        raise exception 'not_authenticated' using errcode = '28000';
    end if;

    if exists (select 1 from public.meetings where user_id = v_user) then
        return null;
    end if;

    v_name := coalesce(public._display_name(v_user), 'you');
    v_started := now() - interval '11 minutes';
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
        ),
        jsonb_build_object(
            'title', 'Two shortcuts worth learning',
            'bullets', jsonb_build_array(
                jsonb_build_object('text',
                    '⌘⇧H shows and hides the panel. ⌘⇧K opens search and Ask from anywhere, without going to the window first.'),
                jsonb_build_object('text',
                    'Both are rebindable in Settings › Shortcuts, and neither needs Nod to be the app in front.')
            )
        ),
        jsonb_build_object(
            'title', 'Ambient context, if you want it',
            'bullets', jsonb_build_array(
                jsonb_build_object('text',
                    'Off until you turn it on, and with it off nothing about your screen is read, stored or sent.'),
                jsonb_build_object('text',
                    'On, it reads the text of your frontmost window — the same text a screen reader would — so "what was I working on this morning" is answerable from what you had open, not only from what was said out loud.'),
                jsonb_build_object('text',
                    'Windows that describe nothing to macOS are read from a picture of that one window, on your Mac, at most once every twenty seconds. The image is never stored and never leaves your Mac.'),
                jsonb_build_object('text',
                    'Apps on your blocklist are skipped before anything is looked at, you can pause it for a few minutes, and what it keeps expires on its own after 14 days.')
            )
        )
    );

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
        jsonb_build_object('text', 'Try ⌘⇧K — it opens search and Ask from wherever you are', 'done', false),
        jsonb_build_object('text', 'Record your first real session — a meeting, a call, or a voice note', 'done', false)
    );

    insert into public.meetings (
        id, user_id, started_at, ended_at, title, summary, recap_json, kind, language,
        speaker_names, origin
    ) values (
        v_meeting,
        v_user,
        v_started,
        v_started + interval '10 minutes',
        v_name || ' <> Nod',
        v_summary,
        jsonb_build_object('sections', v_sections, 'action_items', jsonb_build_array()),
        'meeting',
        'en',
        jsonb_build_object('1', 'Nod'),
        'welcome'
    );

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
            (9, 'me',   'Do I have to open the window every time?'),
            (10, 'them', 'No. ⌘⇧H shows and hides the panel, and ⌘⇧K opens search and Ask from wherever you are — in a browser, in your editor, mid-call. Neither needs Nod to be the app in front, and you can rebind both in Settings under Shortcuts.'),
            (11, 'me',  'I saw an "Ambient context" switch in the sidebar. What does that one do?'),
            (12, 'them', 'It is off until you turn it on, and while it is off nothing about your screen is read, stored or sent. Turn it on and Nod reads the text of your frontmost window — the same text a screen reader would — so that "what was I working on this morning" can be answered from what you had open, not only from what was said out loud.'),
            (13, 'me',  'What about apps that do not expose their text?'),
            (14, 'them', 'Chat apps and design tools mostly draw themselves rather than describe themselves. For those, and only those, Nod takes a picture of that one window and reads the text out of it on your Mac, at most once every twenty seconds. The image is never stored and never leaves your Mac — only the text survives the call.'),
            (15, 'me',  'And if there is something I never want it to see?'),
            (16, 'them', 'Put the app on the blocklist and it is skipped before anything is looked at, rather than filtered out afterwards. You can also pause it for a few minutes when a call needs privacy, and it turns itself back on so you do not have to remember. What it keeps expires on its own after fourteen days, or seven or thirty if you would rather.'),
            (17, 'me',  'What about the things I say I will do?'),
            (18, 'them', 'Nod follows those across sessions, so something you promised three weeks ago comes back before your next call with the same person.'),
            (19, 'me',  'Right. Where do I start?'),
            (20, 'them', 'The checklist above this transcript. Tick the first one off — that is the whole interaction.')
          ) as t(idx, source, text)
    loop
        insert into public.meeting_transcripts (meeting_id, user_id, source, text, ts, idx, speaker)
        values (
            v_meeting,
            v_user,
            v_line.source,
            v_line.text,
            v_started + (v_line.idx * interval '28 seconds'),
            v_line.idx,
            case when v_line.source = 'them' then 1 else null end
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

revoke all on function public.seed_welcome_session() from public, anon;
grant execute on function public.seed_welcome_session() to authenticated;

-- Samples already seeded on this branch keep the transcript they were given.
-- Rewriting one would edit notes somebody may have already edited themselves,
-- and the two paragraphs they are missing are answered by the openers beside
-- the session anyway. New accounts get the fuller version.
