-- Tighten the `meeting_transcripts` insert policy so the row's
-- `meeting_id` must reference a meeting the caller actually owns. The
-- previous policy only checked `auth.uid() = user_id`, leaving a write
-- surface where an authenticated user could (with knowledge of another
-- user's `meeting_id`) insert transcript rows attached to that meeting.
-- They'd never read them back (the read policy filters by user_id), but
-- they'd consume storage and could be used to spam the table or probe
-- meeting existence.
--
-- The exists-subselect runs against the same `meetings` RLS, so the
-- caller can only "see" their own meetings here — meaning the policy
-- effectively requires that the meeting belongs to them.
--
-- Follow-up to `20260527093241_meeting_transcripts.sql`.

drop policy if exists "users insert own transcripts" on public.meeting_transcripts;

create policy "users insert own transcripts"
    on public.meeting_transcripts
    for insert
    to authenticated
    with check (
        auth.uid() = user_id
        and exists (
            select 1
            from public.meetings m
            where m.id = meeting_id
              and m.user_id = auth.uid()
        )
    );
