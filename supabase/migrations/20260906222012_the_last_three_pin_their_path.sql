-- The three public functions the security advisor still lists with a mutable
-- search_path. None reads an unqualified object, so an empty path changes
-- nothing about what they resolve; it only closes the door on a schema shadow.
-- `_excluded_emails` had its path pinned once and lost it: a later
-- `create or replace` without the clause resets proconfig.

alter function public._excluded_emails() set search_path = '';
alter function public.raise_minimum_build(text, integer) set search_path = '';
alter function public.action_items_sync_loop_state() set search_path = '';

revoke all on function public.action_items_sync_loop_state() from public;
