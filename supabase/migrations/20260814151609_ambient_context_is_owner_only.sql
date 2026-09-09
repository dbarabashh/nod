-- Ambient screen text is readable by the person who captured it, and by nobody
-- else, ever — enforced rather than merely true today.
--
-- It is already owner-only, but only because no sharing policy has been written
-- yet. Postgres OR-combines permissive policies, so the day folder sharing lands
-- one copied line adds `screen_observations` to the tables an overlay reaches,
-- and nothing in the schema objects. That is the same shape as the abandoned
-- NOD-31 overlay this branch removed, which had attached itself to four tables
-- nobody had thought about individually.
--
-- A RESTRICTIVE policy is the difference. Postgres AND-combines those with the
-- permissive set, so every future rule still has to get past this one, and no
-- amount of adding widens it. Making the guarantee structural is the whole
-- point: `security.md` promises administrators cannot read ambient text, and a
-- promise kept by absence is a promise waiting to be broken by a diff.
--
-- Why this table and not its neighbours: ambient capture is something the person
-- switched on for themselves, excluded apps from, and set a lifetime for
-- (`privacy.md` § 3.10). Sharing it would not be a wider version of that
-- consent, it would be a different one. `session_embeddings` deliberately does
-- NOT get this treatment — it is derived from transcripts, so if a transcript
-- ever becomes shareable through a folder its index has to follow, or search
-- across shared work silently returns nothing.

create policy "ambient context never leaves its owner"
    on public.screen_observations
    as restrictive
    for all
    to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);
