-- Somewhere to talk about it — with Slack as the first product that serves it.
--
-- The capability is "open a place for this conversation and put the right
-- people in it". Which product that is belongs to the company: Teams, Telegram,
-- Discord and Mattermost are the same sentence to the person asking, and a
-- schema that said `slack_channels` would have to be rewritten for the second
-- customer rather than extended. So what lands here is two action *types* and
-- one adapter behind them; the next adapter is a row in this constraint.
--
-- It is also the first capability whose actions do not exist without `people`.
-- A tracker issue can be filed with nobody on it and still be useful; "create a
-- channel and add Anna, Alex and John" is nothing at all without three member
-- ids, and there is no honest route from three first names to three ids except
-- through the identity table (`20260816200000`).
--
-- Two action types and no more. Creating a space and inviting colleagues are
-- additive and visible to everybody they affect — an unwanted channel is left,
-- an unwanted invitation is declined. Posting messages under the user's name,
-- archiving channels and removing members are none of those things, and a
-- meeting has never needed them.

alter table public.integration_connections
    drop constraint integration_connections_provider_check;

alter table public.integration_connections
    add constraint integration_connections_provider_check
    check (provider in ('linear', 'google-calendar', 'slack'));

-- Inviting exists as a type on its own, not only folded into creation: adding
-- somebody to a space that already exists is what a meeting most often actually
-- decides.
alter table public.action_proposals
    drop constraint action_proposals_type_check;

alter table public.action_proposals
    add constraint action_proposals_type_check
    check (type in (
        'linear.create_issue',
        'linear.update_issue',
        'google-calendar.create_event',
        'slack.create_channel',
        'slack.invite_users'
    ));

-- Disconnecting takes the identities that connection taught us with it.
--
-- `person_identities` outlives any one proposal on purpose — learning a
-- workspace once is what makes the second assignment free — but it is also a
-- record of who a colleague is inside a product this account no longer reaches.
-- `20260815145530` set the rule that unlinking a provider purges what came from
-- it, and hung it on the connection row rather than on the button, because three
-- different paths end a connection and only one of them would remember to clean
-- up. Same rule, same hook, extended from what a provider was read for to what
-- it was learned from.
create or replace function public._purge_provider_data()
    returns trigger
    language plpgsql
    security definer
    set search_path = ''
as $$
declare
    v_user     uuid;
    v_provider text;
begin
    if tg_op = 'DELETE' then
        v_user := old.user_id;
        v_provider := old.provider;
    elsif new.revoked_at is not null and old.revoked_at is null then
        v_user := new.user_id;
        v_provider := new.provider;
    else
        return null;
    end if;

    -- Linear stores nothing here: a filed issue lives in Linear, and the link on
    -- an action item is the user's own record of where their work went.
    if v_provider = 'google-calendar' then
        delete from public.calendar_events
         where user_id = v_user and provider = v_provider;
        delete from public.calendar_sync_state
         where user_id = v_user and provider = v_provider;
    end if;

    -- Only where nobody else is still connected to that provider. A colleague
    -- who keeps their own Slack linked keeps the workspace reachable, and
    -- erasing the mapping would make their next assignment re-read a directory
    -- that never went anywhere.
    delete from public.person_identities pi
     using public.people pe
     where pi.person_id = pe.id
       and pi.provider = v_provider
       and pe.org_id in (
           select org_id from public.org_members
            where user_id = v_user and status = 'active'
       )
       and not exists (
           select 1
             from public.integration_connections ic
             join public.org_members om
               on om.user_id = ic.user_id and om.org_id = pe.org_id and om.status = 'active'
            where ic.provider = v_provider
              and ic.revoked_at is null
              and ic.user_id <> v_user
       );

    return null;
end;
$$;
