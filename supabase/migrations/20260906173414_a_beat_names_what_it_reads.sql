-- Which connected products a beat may read. Null means every product the
-- person has connected, which is what every beat did before this column; an
-- empty array means none, the beat answers from Nod's own record alone. Kept
-- as provider slugs rather than a foreign key: a beat outlives a connection,
-- and a product that is disconnected is simply not offered at run time.

alter table public.beats
    add column if not exists providers text[];

comment on column public.beats.providers is
    'Connected products this beat may read; null = every connected product, {} = none.';
