// Dark-launch gates for the context-platform rewrite (see
// nod-context-platform-implementation-plan.md, Phase 1). Same shape as
// `KNOWLEDGE_READ_ENABLED` in `knowledge.ts`: unset reads as off, so every
// later phase ships dark until a branch's secret explicitly turns it on.

function flag(name: string): boolean {
  return Deno.env.get(name) === "true";
}

/// Phase 2+: universal ingestion jobs/cursors writing `source_objects` etc.
export function ingestionV2Enabled(): boolean {
  return flag("INGESTION_V2");
}

/// Phase 6: `context_nodes`/`context_edges`/`workstreams` writers.
export function contextGraphWriteEnabled(): boolean {
  return flag("CONTEXT_GRAPH_WRITE");
}

/// Phase 7: cross-source retrieval consuming the graph and `source_chunks`.
export function retrievalV2Enabled(): boolean {
  return flag("RETRIEVAL_V2");
}

/// Phase 8: the `briefings`/`briefing_items` worker and Home's synthesis card.
export function briefingsV1Enabled(): boolean {
  return flag("BRIEFINGS_V1");
}

/// Phase 10: proposals/actions resolving against context nodes instead of a
/// mandatory `meeting_id`.
export function actionContextV2Enabled(): boolean {
  return flag("ACTION_CONTEXT_V2");
}
