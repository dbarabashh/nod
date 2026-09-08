import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1.0.14";
import { isMetered, isProposable } from "./metering.ts";

Deno.test("a write is never metered, whoever made it", () => {
  for (
    const action of [
      "create_issue",
      "update_task",
      "append_page",
      "comment_issue",
      "invite_users",
      "post_message",
      "delete_event",
      "respond_to_event",
      "create_draft",
    ]
  ) {
    assertFalse(isMetered(action, "chat"));
    assertFalse(isMetered(action, "app"));
    assertFalse(isMetered(action, undefined));
  }
});

Deno.test("a read the chat makes is metered", () => {
  for (
    const action of [
      "search_messages",
      "read_page",
      "list_events",
      "find_contact",
      "campaign_performance",
      "read_issue",
    ]
  ) {
    assert(isMetered(action, "chat"));
    assert(isMetered(action, undefined));
  }
});

Deno.test("only the app's own reads are exempt, and only when it says so", () => {
  for (
    const action of [
      "read_issues",
      "read_tasks",
      "search_issues",
      "search_tasks",
      "check_availability",
      "list_users",
      "list_channels",
    ]
  ) {
    assertFalse(isMetered(action, "app"));
    assert(isMetered(action, "chat"));
    assert(isMetered(action, undefined));
  }
  assert(isMetered("search_messages", "app"));
  assert(isMetered("read_page", "app"));
});

Deno.test("only a write can be proposed", () => {
  for (const action of ["create_issue", "post_message", "create_note", "create_event", "update_issue"]) {
    assertEquals(isProposable(action), true, action);
  }
  for (const action of ["search_issues", "read_thread", "list_users", "find_contact", "read_document"]) {
    assertEquals(isProposable(action), false, action);
  }
});
