-- Merging into a recording you cannot read leaves you with nothing.
--
-- `merge_meeting` checked that the target was one a matcher would have offered,
-- and stopped there. But the colleague matcher offers recordings belonging to
-- other people, and another person's meeting is not readable until they share
-- it — that is the whole point of `meeting_grants`. So the honest-looking move
-- was destructive: your own copy stops being a meeting of its own and drops out
-- of every list, the other one stays invisible, and the conversation is gone
-- from where you look for it.
--
-- The case is not hypothetical. Two people recorded one call; one of the two
-- recordings captured only its owner's microphone and is half a conversation.
-- The complete one belongs to the other person. Offering to file them as one
-- while the complete one is unreadable would have taken away the half that
-- worked.
--
-- So: merge into your own recording freely, and into somebody else's only once
-- they have shared it. Nothing here shares anything — it refuses.

create or replace function public.merge_meeting(p_source uuid, p_target uuid)
    returns void
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_ok boolean;
    v_target_owner uuid;
begin
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;
    if p_source = p_target then
        raise exception 'a meeting cannot be merged into itself' using errcode = '22023';
    end if;

    -- The target has to be one a matcher would have offered. Without this the
    -- function would let any meeting id be written into anybody's row, and the
    -- boundaries the matchers enforce would be decoration. Both matchers count:
    -- a colleague's recording of the same call, or your own of the same room.
    select exists (
        select 1 from public.same_meeting_in_org(p_source) c where c.meeting_id = p_target
        union all
        select 1 from public.my_earlier_recording(p_source) c where c.meeting_id = p_target
    ) into v_ok;
    if not v_ok then
        raise exception 'those are not the same meeting' using errcode = '42501';
    end if;

    -- And it has to be one you can still open afterwards.
    select m.user_id into v_target_owner from public.meetings m where m.id = p_target;
    if v_target_owner is distinct from auth.uid()
       and not public.can_read_meeting_via_grant(p_target) then
        raise exception 'that recording has not been shared with you' using errcode = '42501';
    end if;

    -- A merged recording is no longer its own meeting, so it must stop counting
    -- as one. Nothing is deleted: the transcript stays readable under the row it
    -- was captured in, and `merged_into` is what every list and every window
    -- query already filters on.
    update public.meetings
       set merged_into = p_target
     where id = p_source and user_id = auth.uid();
end;
$$;

revoke all on function public.merge_meeting(uuid, uuid) from public, anon;
grant execute on function public.merge_meeting(uuid, uuid) to authenticated;
