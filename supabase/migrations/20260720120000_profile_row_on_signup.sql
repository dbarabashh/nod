-- Create the profile row at signup instead of waiting for the client upsert.
--
-- `llm-proxy` stamps the client's build/version onto `profiles` with an
-- `update` (deliberately, so the proxy never creates half-empty rows). But the
-- row itself was only written by the client's onboarding/Settings upsert, which
-- lands seconds AFTER the app's first proxy call — so for a fresh user the
-- stamp matched zero rows, and anyone who signed up without ever recording a
-- meeting stayed at `app_version = null` forever (two of the three signups on
-- 2026-07-20). Creating the row on the auth.users insert closes that race and
-- makes `profiles` a complete mirror of the user table, the same way
-- `handle_new_user_subscription` already does for trials.
--
-- `display_name` is seeded from the OAuth identity metadata using the same key
-- order as the client (`User.profileDisplayName`), so the value the user sees
-- pre-filled in onboarding matches what's already stored.

create or replace function public.handle_new_user_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.profiles (user_id, display_name)
    values (
        new.id,
        nullif(coalesce(
            new.raw_user_meta_data ->> 'full_name',
            new.raw_user_meta_data ->> 'name',
            new.raw_user_meta_data ->> 'user_name',
            ''
        ), '')
    )
    on conflict (user_id) do nothing;
    return new;
end;
$$;

create trigger on_auth_user_created_profile
    after insert on auth.users
    for each row execute function public.handle_new_user_profile();

-- Backfill users who signed up before the trigger existed.
insert into public.profiles (user_id, display_name)
select
    id,
    nullif(coalesce(
        raw_user_meta_data ->> 'full_name',
        raw_user_meta_data ->> 'name',
        raw_user_meta_data ->> 'user_name',
        ''
    ), '')
from auth.users
on conflict (user_id) do nothing;
