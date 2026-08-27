-- The meeting-detail page asks "which loops did this meeting move" on every
-- open, by containment against `evidence`. Without an index that is a sequential
-- scan of the user's whole transition history to answer, almost always, "none".
create index if not exists action_item_transitions_evidence_idx
    on public.action_item_transitions using gin (evidence jsonb_path_ops);
