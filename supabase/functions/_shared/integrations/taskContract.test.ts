import { assert, assertEquals } from "jsr:@std/assert@1.0.14";
import { handlerFor } from "./registry.ts";
import { TASK_PROVIDERS, taskReference } from "./taskContract.ts";

// The desktop swaps only the provider name between trackers; every one of them
// has to answer all four verbs or a checkbox finds out.
Deno.test("every tracker answers create, search, read status and update", () => {
    for (const tracker of TASK_PROVIDERS) {
        for (const action of [tracker.create, tracker.search, tracker.readStatus, tracker.update]) {
            assert(handlerFor(tracker.provider, action), `${tracker.provider} has no ${action}`);
        }
    }
});

Deno.test("issue trackers and task lists spell the verbs their own way", () => {
    assertEquals(TASK_PROVIDERS.map((tracker) => tracker.provider), ["linear", "jira", "asana", "google-tasks"]);
    for (const tracker of TASK_PROVIDERS) {
        const noun = tracker.provider === "linear" || tracker.provider === "jira" ? "issue" : "task";
        assertEquals(tracker.create, `create_${noun}`);
        assertEquals(tracker.update, `update_${noun}`);
        assertEquals(tracker.search, `search_${noun}s`);
        assertEquals(tracker.readStatus, `read_${noun}s`);
    }
});

Deno.test("a reference always carries the four words, with extras riding along", () => {
    assertEquals(
        taskReference({ key: "NOD-3", title: "Ship it", url: "https://x/NOD-3", closed: true, state: "Done" }),
        { key: "NOD-3", title: "Ship it", url: "https://x/NOD-3", closed: true, state: "Done" },
    );
    assertEquals(taskReference({ key: "1" }), { key: "1", title: "", closed: false });
    assertEquals(taskReference({ key: "1", title: null, url: "", closed: null }), { key: "1", title: "", closed: false });
});
