-- Nine foreign keys the performance advisor flagged as uncovered after
-- `20260903123527_context_platform_graph_evidence_briefings.sql`.
create index briefing_item_evidence_evidence_ref_idx on public.briefing_item_evidence (evidence_ref_id);
create index briefing_items_target_node_idx on public.briefing_items (target_node_id) where target_node_id is not null;
create index briefings_org_idx on public.briefings (org_id) where org_id is not null;
create index briefings_target_node_idx on public.briefings (target_node_id) where target_node_id is not null;
create index context_edges_org_idx on public.context_edges (org_id) where org_id is not null;
create index context_edges_user_idx on public.context_edges (user_id);
create index context_nodes_org_idx on public.context_nodes (org_id) where org_id is not null;
create index evidence_refs_org_idx on public.evidence_refs (org_id) where org_id is not null;
create index evidence_refs_source_chunk_idx on public.evidence_refs (source_chunk_id) where source_chunk_id is not null;
