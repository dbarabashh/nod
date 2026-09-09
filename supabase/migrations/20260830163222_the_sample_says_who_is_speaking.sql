-- The sample says who is speaking.
--
-- The welcome session's transcript rendered as THEM / ME, which is right for a
-- recording of strangers and wrong for a written conversation whose two parties
-- are named in its own title. Nod's side is now labelled "Nod".
--
-- Through `speaker_names`, the mechanism a real session already uses, rather
-- than anything the sample gets to itself: `TranscriptRecord.displayLabel`
-- reads a diarized cluster number out of that map, so naming cluster 1 is the
-- same act as somebody correcting a speaker on a meeting they recorded.
--
-- The user's own side keeps saying "Me". Not an omission: `me` is the one
-- source `TranscriptSource.isClustered` excludes — a routed microphone is one
-- known voice and never gets a cluster — so there is no cluster to name, and
-- every real session labels the user's own lines the same way. A sample that
-- said "Dima B" there would be teaching a label that never appears again.
--
-- A forward migration rather than an edit to the one that shipped: that one is
-- applied, and editing it would leave a fresh environment and this branch with
-- different histories that both claim the same version.

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
        id, user_id, started_at, ended_at, title, summary, recap_json, kind, language,
        speaker_names, origin
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
        -- Cluster 1 is the only voice on the `them` stream. Sparse by design:
        -- the map names what is known and nothing else.
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
            (9, 'me',   'What about the things I say I will do?'),
            (10, 'them', 'Nod follows those across sessions, so something you promised three weeks ago comes back before your next call with the same person.'),
            (11, 'me',  'Right. Where do I start?'),
            (12, 'them', 'The checklist above this transcript. Tick the first one off — that is the whole interaction.')
          ) as t(idx, source, text)
    loop
        insert into public.meeting_transcripts (meeting_id, user_id, source, text, ts, idx, speaker)
        values (
            v_meeting,
            v_user,
            v_line.source,
            v_line.text,
            v_started + (v_line.idx * interval '25 seconds'),
            v_line.idx,
            -- Only the `them` stream carries a cluster. `me` is excluded by
            -- `TranscriptSource.isClustered`, so a number there would be read
            -- by nothing and mean nothing.
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

-- Samples already seeded on this branch, brought up to the same labelling.
-- Scoped to `origin = 'welcome'`: nothing here may touch a session somebody
-- actually recorded.
update public.meeting_transcripts t
   set speaker = 1
  from public.meetings m
 where m.id = t.meeting_id
   and m.origin = 'welcome'
   and t.source = 'them'
   and t.speaker is null;

update public.meetings
   set speaker_names = jsonb_build_object('1', 'Nod')
 where origin = 'welcome'
   and speaker_names is null;
