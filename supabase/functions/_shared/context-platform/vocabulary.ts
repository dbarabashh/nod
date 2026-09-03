// The shared vocabulary for the context platform's `source_objects` and
// `context_edges` (see nod-context-platform-implementation-plan.md §6.2/§6.4).
// Provider names are NOT redefined here — `integrations/registry.ts` already
// owns that list (`isConnectableProvider`); this only names the two things
// that table doesn't: what kind of object a source produced, and how two
// context nodes relate.

/// `source_objects.object_type`, always `"<provider>/<kind>"`. The provider
/// half need not be a connectable broker provider — `ambient` and `nod` are
/// first-party sources, not Pipedream apps.
export type SourceObjectType =
  | "google-calendar/event"
  | "granola/meeting"
  | "fathom/transcript"
  | "gmail/thread"
  | "linear/issue"
  | "github/pull_request"
  | "google-drive/document"
  | "notion/page"
  | "ambient/window_observation"
  | "nod/meeting";

export const SOURCE_OBJECT_TYPES: ReadonlySet<SourceObjectType> = new Set([
  "google-calendar/event",
  "granola/meeting",
  "fathom/transcript",
  "gmail/thread",
  "linear/issue",
  "github/pull_request",
  "google-drive/document",
  "notion/page",
  "ambient/window_observation",
  "nod/meeting",
]);

/// `context_edges.relation`.
export type ContextRelation =
  | "same_event"
  | "mentions"
  | "attended_by"
  | "discussed"
  | "references"
  | "created_after"
  | "implements"
  | "blocks"
  | "resolves"
  | "resulted_in"
  | "supersedes"
  | "same_workstream"
  | "viewed_during";

export const CONTEXT_RELATIONS: ReadonlySet<ContextRelation> = new Set([
  "same_event",
  "mentions",
  "attended_by",
  "discussed",
  "references",
  "created_after",
  "implements",
  "blocks",
  "resolves",
  "resulted_in",
  "supersedes",
  "same_workstream",
  "viewed_during",
]);

/// The linker's deterministic-before-semantic priority order (§7.3). Lower is
/// stronger; a linker citing a signal not in this list is citing one the plan
/// never authorized.
export type LinkSignal =
  | "exact_external_id"
  | "calendar_identity"
  | "canonical_url"
  | "explicit_reference"
  | "person_time_overlap"
  | "semantic_similarity"
  | "temporal_sequence";

export const LINK_SIGNAL_PRIORITY: readonly LinkSignal[] = [
  "exact_external_id",
  "calendar_identity",
  "canonical_url",
  "explicit_reference",
  "person_time_overlap",
  "semantic_similarity",
  "temporal_sequence",
];

/// §7.3 confidence policy: what a link's confidence number is allowed to do.
export type LinkAction = "auto_edge" | "candidate_edge" | "discard";

export function linkActionFor(confidence: number): LinkAction {
  if (confidence >= 0.9) return "auto_edge";
  if (confidence >= 0.7) return "candidate_edge";
  return "discard";
}
