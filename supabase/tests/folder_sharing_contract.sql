-- What a shared folder lets a teammate do.
--
-- The whole point of `meeting_labels`' write policies is which of these four
-- combinations of "whose session" × "whose folder" is allowed. Getting one of
-- them wrong is not a visible bug — it is either a teammate who cannot use a
-- folder that says it is shared, or somebody's recording re-shared to a group
-- they never gave it to.

begin;

insert into auth.users (id, email, created_at, updated_at)
values
    ('60000000-0000-4000-8000-000000000001', 'folder-owner@example.invalid', now(), now()),
    ('60000000-0000-4000-8000-000000000002', 'folder-guest@example.invalid', now(), now()),
    ('60000000-0000-4000-8000-000000000003', 'folder-stranger@example.invalid', now(), now());

insert into public.organizations (id, name, slug, created_by)
values ('61000000-0000-4000-8000-000000000001', 'Folder Co', 'folder-co',
        '60000000-0000-4000-8000-000000000001');

insert into public.org_members (org_id, user_id, role, status)
values
    ('61000000-0000-4000-8000-000000000001', '60000000-0000-4000-8000-000000000001', 'owner', 'active'),
    ('61000000-0000-4000-8000-000000000001', '60000000-0000-4000-8000-000000000002', 'member', 'active'),
    ('61000000-0000-4000-8000-000000000001', '60000000-0000-4000-8000-000000000003', 'member', 'active');

insert into public.teams (id, org_id, name, created_by)
values ('62000000-0000-4000-8000-000000000001', '61000000-0000-4000-8000-000000000001', 'Product',
        '60000000-0000-4000-8000-000000000001');

-- The stranger is in the organization but not in the team the folder reaches.
insert into public.team_members (team_id, user_id)
values
    ('62000000-0000-4000-8000-000000000001', '60000000-0000-4000-8000-000000000001'),
    ('62000000-0000-4000-8000-000000000001', '60000000-0000-4000-8000-000000000002');

insert into public.labels (id, user_id, name)
values
    ('63000000-0000-4000-8000-000000000001', '60000000-0000-4000-8000-000000000001', 'Shared folder'),
    ('63000000-0000-4000-8000-000000000002', '60000000-0000-4000-8000-000000000001', 'Private folder'),
    ('63000000-0000-4000-8000-000000000003', '60000000-0000-4000-8000-000000000002', 'Guest folder');

insert into public.folder_shares (label_id, team_id, shared_by)
values ('63000000-0000-4000-8000-000000000001', '62000000-0000-4000-8000-000000000001',
        '60000000-0000-4000-8000-000000000001');

insert into public.meetings (id, user_id, title, started_at, ended_at, summary)
values
    ('64000000-0000-4000-8000-000000000001', '60000000-0000-4000-8000-000000000001',
     'Owner session', now(), now(), ''),
    ('64000000-0000-4000-8000-000000000002', '60000000-0000-4000-8000-000000000002',
     'Guest session', now(), now(), '');

set local role authenticated;
set local request.jwt.claims = '{"sub":"60000000-0000-4000-8000-000000000002"}';

-- The case that was broken: the guest files their own session into a folder
-- that was shared with them.
insert into public.meeting_labels (user_id, meeting_id, label_id)
values ('60000000-0000-4000-8000-000000000002',
        '64000000-0000-4000-8000-000000000002',
        '63000000-0000-4000-8000-000000000001');

do $$
begin
    -- Their own folder still works, which the old policy also allowed.
    insert into public.meeting_labels (user_id, meeting_id, label_id)
    values ('60000000-0000-4000-8000-000000000002',
            '64000000-0000-4000-8000-000000000002',
            '63000000-0000-4000-8000-000000000003');

    -- A folder nobody shared with them is not reachable.
    begin
        insert into public.meeting_labels (user_id, meeting_id, label_id)
        values ('60000000-0000-4000-8000-000000000002',
                '64000000-0000-4000-8000-000000000002',
                '63000000-0000-4000-8000-000000000002');
        raise exception 'a guest filed into a folder that was never shared with them';
    exception when insufficient_privilege then null;
    end;

    -- The line that must not move: somebody else's session, into a folder the
    -- guest can reach, would re-share a recording its owner never gave away.
    begin
        insert into public.meeting_labels (user_id, meeting_id, label_id)
        values ('60000000-0000-4000-8000-000000000002',
                '64000000-0000-4000-8000-000000000001',
                '63000000-0000-4000-8000-000000000001');
        raise exception 'a guest filed somebody elses session into a shared folder';
    exception when insufficient_privilege then null;
    end;
end;
$$;

-- Filing into the shared folder is what makes the session readable to the
-- folder's audience — the reason writing here is disclosure, and the reason it
-- is restricted to your own sessions.
do $$
begin
    if not public.can_read_meeting_via_folder('64000000-0000-4000-8000-000000000002') then
        raise exception 'a session filed in a shared folder did not become readable through it';
    end if;
end;
$$;

-- The stranger is in the organization but not the team, so the share does not
-- reach them at all.
set local request.jwt.claims = '{"sub":"60000000-0000-4000-8000-000000000003"}';

do $$
begin
    if public.can_read_folder('63000000-0000-4000-8000-000000000001') then
        raise exception 'a folder shared with one team reached somebody outside it';
    end if;
end;
$$;

-- The owner curates their own folder: they can take out what a teammate put in,
-- which nobody could do while only the author of a link could remove it.
set local request.jwt.claims = '{"sub":"60000000-0000-4000-8000-000000000001"}';

do $$
declare
    v_removed int;
begin
    delete from public.meeting_labels
     where meeting_id = '64000000-0000-4000-8000-000000000002'
       and label_id = '63000000-0000-4000-8000-000000000001';
    get diagnostics v_removed = row_count;
    if v_removed <> 1 then
        raise exception 'a folder owner could not unfile a teammates session';
    end if;
end;
$$;

-- ...and only their own folder. The guest's folder is not theirs to curate.
do $$
declare
    v_removed int;
begin
    delete from public.meeting_labels
     where label_id = '63000000-0000-4000-8000-000000000003';
    get diagnostics v_removed = row_count;
    if v_removed <> 0 then
        raise exception 'a folder owner reached into somebody elses folder';
    end if;
end;
$$;

rollback;
