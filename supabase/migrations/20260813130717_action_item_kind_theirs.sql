-- A task somebody else took on, in a conversation the user was part of.
--
-- Until now the recap had two answers for one: a commitment either became the
-- user's own checkable to-do or it was dropped. The rule that forced the
-- choice — "every action must have an owner, otherwise drop it" — reads as
-- caution and behaves as loss on the calls where it matters most: a meeting
-- someone attends and barely speaks at is nothing but other people's
-- commitments, so the checklist comes out empty while the room clearly took on
-- work. Observed on a recorded call where the live pass heard "shift what you
-- picked up in Colin's absence over to Tracy", verified the quote against the
-- transcript, showed it, and then retired the row at finalize because the
-- recap could not name the user as its owner.
--
-- `theirs` is that third answer. It is NOT the owner/assignee column this
-- table deliberately does not have (see 20260806164035): nobody is assigned
-- anything, the person stays named inside `text` exactly as the recap wrote
-- it, and this remains a single-user product. The column answers one narrower
-- question — is this the user's to do? — which is precisely what decides
-- whether a row belongs in their checklist, their counts, and the "what should
-- I do" answers built from them.
--
-- No query changes follow from this. `ActionItemStore.allItems` already
-- selects `kind = 'action'`, so nothing new reaches the task list; `notes`
-- selects `kind <> 'action'`, so these surface beside the meeting's decisions
-- and open questions, where they are read and not acted on.

alter table public.action_items
    drop constraint if exists action_items_kind_check,
    add constraint action_items_kind_check
        check (kind in ('action', 'theirs', 'decision', 'question', 'risk', 'follow_up'));
