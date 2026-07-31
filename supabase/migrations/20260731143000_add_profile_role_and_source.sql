-- Who signs up, and where they came from.
--
-- Both are answered once in onboarding and both are optional. Deliberately
-- plain text with no check constraint or enum: adding a role or a channel
-- should be a client release, not a migration — same call as
-- `onboarding_events.event`.
--
-- `role` is for segmentation and for picking the user's starting meeting mode.
-- It is NOT prompt context: a role line in the LLM prompt was removed once
-- already for being wrong on the non-work sessions this profile also feeds
-- (see Profile.promptBlock).

alter table public.profiles
    add column if not exists role text,
    add column if not exists heard_from text;

comment on column public.profiles.role is
    'What the user does (founder, recruiter, sales, …). Segmentation + default meeting mode. Never sent to the LLM.';

comment on column public.profiles.heard_from is
    'Acquisition channel as self-reported at onboarding (friend, search, twitter, …).';
