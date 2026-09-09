-- A browser capture keeps the page's address.
--
-- The address was already read before anything else — the blocklist is checked
-- against it — and then dropped, so "send me back that link" could only be
-- answered when the omnibox happened to be in the captured text. Kept now for a
-- page that passed the check, under the row's own `expires_at` like the rest
-- of it. Null for every app that is not a browser, and for every row written
-- before this column existed. Decision D0028 in the playbook.

alter table public.screen_observations
    add column source_url text;
