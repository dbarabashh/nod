-- Bring the already-seeded samples up to date.
--
-- The previous migration left them alone on the reasoning that somebody may
-- have edited the notes. That was too blunt: the seed only ever fires into an
-- account with no sessions at all, so a sample that misses the shortcuts and
-- the ambient-context paragraphs misses them permanently — deleting it does not
-- earn a fresh one.
--
-- So: update what is safe to update, and prove the rest is untouched before
-- touching it.
--
-- * The transcript is rewritten unconditionally. Nothing in the app edits
--   transcript text — `SpeakerCorrection` renames a speaker, it does not
--   rewrite what was said — so there is no work here to lose.
-- * The notes are rewritten only where `recap_json->'sections'` still equals
--   what the first revision generated. `EditableRecap` writes `recap_json` and
--   the rendered `summary` together, so that comparison is an exact test of
--   "nobody has corrected a line of this".
-- * The new checklist row is inserted only where it is absent, and every
--   existing row keeps its own `done` state. A migration that unticked
--   somebody's box would be worse than one that shipped stale copy.

do $$
declare
    v_old_sections jsonb := jsonb_build_array(
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
    v_new_sections jsonb := jsonb_build_array(
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
    v_summary text;
    v_name text;
    v_m record;
begin
    -- Rendered from the sections, the same way the seed does, so the two can
    -- never say different things.
    select string_agg(block, E'\n\n' order by ord)
      into v_summary
      from (
        select s.ord,
               '**' || (s.section->>'title') || '**' || E'\n' ||
               (select string_agg('- ' || (b->>'text'), E'\n')
                  from jsonb_array_elements(s.section->'bullets') b)
               as block
          from jsonb_array_elements(v_new_sections) with ordinality as s(section, ord)
      ) blocks;

    for v_m in
        select id, user_id, started_at
          from public.meetings
         where origin = 'welcome'
           and deleted_at is null
    loop
        v_name := coalesce(public._display_name(v_m.user_id), 'you');

        delete from public.meeting_transcripts where meeting_id = v_m.id;

        insert into public.meeting_transcripts (meeting_id, user_id, source, text, ts, idx, speaker)
        select v_m.id,
               v_m.user_id,
               t.source,
               t.text,
               v_m.started_at + (t.idx * interval '28 seconds'),
               t.idx,
               case when t.source = 'them' then 1 else null end
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
          ) as t(idx, source, text);

        -- The clock follows the transcript it now holds.
        update public.meetings
           set ended_at = started_at + interval '10 minutes'
         where id = v_m.id;

        -- Notes only where nobody has corrected a line.
        update public.meetings
           set summary = v_summary,
               recap_json = jsonb_build_object('sections', v_new_sections, 'action_items', jsonb_build_array())
         where id = v_m.id
           and recap_json->'sections' = v_old_sections;

        -- Make room for the new row, then add it. Both guarded, so running this
        -- against a sample that already has it changes nothing.
        update public.action_items
           set position = 5
         where meeting_id = v_m.id
           and position = 4
           and text like 'Record your first real session%';

        insert into public.action_items (user_id, meeting_id, text, position, done, source)
        select v_m.user_id,
               v_m.id,
               'Try ⌘⇧K — it opens search and Ask from wherever you are',
               4,
               false,
               'recap'
         where not exists (
            select 1 from public.action_items a
             where a.meeting_id = v_m.id
               and a.text like 'Try ⌘⇧K%'
         );
    end loop;
end $$;
