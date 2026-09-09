-- Remove the abandoned NOD-31 workspace overlay wherever it is still installed.
--
-- Its pull request was closed and its migrations reverted, but the objects
-- stayed behind in the sandbox instance: five tables, nineteen functions, and —
-- the reason this is a correctness fix rather than tidying — seven PERMISSIVE
-- SELECT policies still attached to tables the feature did not own.
--
-- Postgres OR-combines permissive policies per command, so in that instance
-- `meetings`, `meeting_transcripts`, `action_items` and `session_embeddings`
-- were each readable either by their owner check or by an overlay predicate
-- belonging to withdrawn, unreviewed work. It returned nothing only because the
-- instance happened to hold a single workspace with a single member; the
-- predicate, not the data, is what decides whether that stays true.
--
-- The second cost is quieter and worse: row-level security there no longer
-- matched production, so any RLS behaviour verified against that instance was
-- verifying a policy set that ships nowhere.
--
-- Every statement is guarded. Production never received these objects, so this
-- is a no-op there, and it stays one for any preview branch cloned after the
-- cleanup. `decks` is deliberately left alone — it is a separate feature that
-- owns its own branch and client code, and it never referenced a workspace.

drop policy if exists "members read shared meetings via folder" on public.meetings;
drop policy if exists "members read shared transcripts via folder" on public.meeting_transcripts;
drop policy if exists "members read shared action_items via folder" on public.action_items;
drop policy if exists "members read shared embeddings via folder" on public.session_embeddings;
drop policy if exists "members read shared folder labels" on public.labels;
drop policy if exists "members read shared meeting_labels via folder" on public.meeting_labels;
drop policy if exists "collaborators file own meeting into shared folder" on public.meeting_labels;

-- Tables before functions: the overlay's own policies are defined in terms of
-- these functions, so dropping a function first fails on the dependency.
drop table if exists public.folder_members cascade;
drop table if exists public.folder_shares cascade;
drop table if exists public.workspace_invites cascade;
drop table if exists public.workspace_members cascade;
drop table if exists public.workspaces cascade;

drop function if exists public._unlink_member_contributions(uuid, uuid);
drop function if exists public.accept_workspace_invite(uuid);
drop function if exists public.add_folder_member(uuid, text, text);
drop function if exists public.can_see_meeting_via_folder(uuid);
drop function if exists public.create_workspace(text);
drop function if exists public.invite_to_workspace(uuid, text, text);
drop function if exists public.is_member(uuid);
drop function if exists public.leave_workspace(uuid);
drop function if exists public.list_folder_members(uuid);
drop function if exists public.list_workspace_members(uuid);
drop function if exists public.match_workspace_chunks(vector, integer, uuid[]);
drop function if exists public.remove_folder_member(uuid, uuid);
drop function if exists public.remove_workspace_member(uuid, uuid);
drop function if exists public.revoke_workspace_invite(uuid);
drop function if exists public.set_workspace_member_role(uuid, uuid, text);
drop function if exists public.share_folder(uuid, uuid, text);
drop function if exists public.unshare_folder(uuid);
drop function if exists public.visible_meeting_ids_in_folder(uuid);
drop function if exists public.workspace_role(uuid, uuid);
