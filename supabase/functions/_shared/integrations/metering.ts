// What an integration action costs at the pool, decided by its name.
//
// A read is metered; a write is not. Filing a ticket after a meeting is what
// every tier promises and costs one call. Asking Nod to read an inbox is the
// agentic use that scales without bound, and the pool exists for that. Decided
// by the verb because every adapter names its actions that way, and a new
// adapter gets the right answer without a table to keep in step.
const FREE_VERBS = [
  "create_",
  "update_",
  "add_",
  "post_",
  "send_",
  "file_",
  "complete_",
  "close_",
  "reopen_",
  "delete_",
  "append_",
  "comment_",
  "invite_",
];

// Reads the app makes for its own screens rather than because the person asked
// a question: the ticket-status mirror, a form's pickers, proposal linking,
// the free-slot check. Each is throttled or bounded on the client, so they
// stay outside the pool when the client says the app made them — and only
// these: a client claiming `app` on any other read is metered anyway.
const APP_READS = new Set([
  "read_issues",
  "read_tasks",
  "search_issues",
  "search_tasks",
  "check_availability",
  "list_users",
  "list_channels",
]);

export function isMetered(action: string, origin: unknown): boolean {
  if (FREE_VERBS.some((verb) => action.startsWith(verb))) return false;
  return !(origin === "app" && APP_READS.has(action));
}
