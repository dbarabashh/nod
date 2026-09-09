-- L2: an agent may prepare proposals a person approves.
--
-- The draft lands in `action_proposals` — the queue the user already answers —
-- and nowhere new. Writing a `proposed` row changes nothing in any connected
-- product: it becomes an action only through the same approve → server-side
-- re-check path every proposal has always taken. What L2 adds is authorship:
-- the row says which agent prepared it, so the card can say so, and so an
-- edit-before-approve or a rejection lands against that agent rather than
-- against the weather.

alter table public.action_proposals
    add column raised_by_agent uuid references public.agents(id) on delete set null;

create index action_proposals_agent_idx
    on public.action_proposals (raised_by_agent) where raised_by_agent is not null;

-- The one thing an L2 agent may draft: the exact proposal type of the habit
-- that earned it. Not a list — the pattern was one shape, the permission is
-- that shape. Null for L1 agents and for anything typed up by hand.
alter table public.agents
    add column draft_type text
    check (draft_type is null or draft_type ~ '^[a-z][a-z0-9-]*\.[a-z_]+$');
