-- Allow the app to backfill diarized speaker labels after the transcript rows
-- have already been inserted. Keep the privilege column-scoped so clients can
-- patch `speaker` without gaining general transcript edit access.

revoke update on public.meeting_transcripts from anon, authenticated;
grant update (speaker) on public.meeting_transcripts to authenticated;

create policy "users update own transcript speakers"
    on public.meeting_transcripts
    for update
    to authenticated
    using (
        auth.uid() = user_id
        and exists (
            select 1
            from public.meetings m
            where m.id = meeting_id
              and m.user_id = auth.uid()
        )
    )
    with check (
        auth.uid() = user_id
        and exists (
            select 1
            from public.meetings m
            where m.id = meeting_id
              and m.user_id = auth.uid()
        )
    );
