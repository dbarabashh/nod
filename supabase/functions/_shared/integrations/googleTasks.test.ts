import { assert, assertEquals, assertFalse, assertThrows } from "jsr:@std/assert@1.0.14";
import { ActionError } from "./errors.ts";
import {
    appended,
    dueOf,
    hasID,
    LIST_QUERY,
    matchScore,
    newTask,
    notesOf,
    orderedForSearch,
    statusOf,
    summarise,
    taskPatch,
    taskPath,
    TASKS_PATH,
    WEB_URL,
} from "./googleTasks.ts";

function refused(run: () => unknown, code = "invalid_params"): ActionError {
    const error = assertThrows(run, ActionError);
    assertEquals(error.code, code);
    return error;
}

Deno.test("every request addresses the default list", () => {
    assertEquals(TASKS_PATH, "tasks/v1/lists/@default/tasks");
    assertEquals(taskPath("abc"), "tasks/v1/lists/@default/tasks/abc");
    assertEquals(taskPath("a/b c"), "tasks/v1/lists/@default/tasks/a%2Fb%20c");
});

// Completed tasks are listed so a commitment already done is found rather than
// filed again; cleared ones are not.
Deno.test("a search lists one page, finished tasks included, cleared ones not", () => {
    assertEquals(LIST_QUERY, { showCompleted: "true", showHidden: "false", maxResults: "100" });
});

Deno.test("a task without an id is not a task", () => {
    assert(hasID({ id: "t1" }));
    assertFalse(hasID({ id: "" }));
    assertFalse(hasID({ title: "x" }));
    assertFalse(hasID(null));
});

// The three words the desktop decodes from every tracker, plus what the
// duplicate check and the model read.
Deno.test("a task is summarised in the trackers' shared words", () => {
    assertEquals(
        summarise({
            id: "t1",
            title: "  Send the deck  ",
            status: "needsAction",
            due: "2026-09-05T00:00:00.000Z",
            updated: "2026-09-02T10:00:00.000Z",
            webViewLink: "https://tasks.google.com/task/t1",
        }),
        {
            key: "t1",
            title: "Send the deck",
            url: "https://tasks.google.com/task/t1",
            closed: false,
            due: "2026-09-05",
            updated: "2026-09-02T10:00:00.000Z",
        },
    );
});

Deno.test("a completed task is closed", () => {
    assert(summarise({ id: "t1", title: "x", status: "completed" }).closed);
    assertFalse(summarise({ id: "t1", title: "x", status: "needsAction" }).closed);
    assertFalse(summarise({ id: "t1", title: "x" }).closed);
});

// The desktop refuses a filing result without a url, and Google sends the
// link only sometimes.
Deno.test("a task without a web link points at Google Tasks itself", () => {
    const summary = summarise({ id: "t1", title: "x" });
    assertEquals(summary.url, WEB_URL);
    assertEquals(summary.due, null);
    assertEquals(summary.updated, null);
});

Deno.test("an untitled task is named as such", () => {
    assertEquals(summarise({ id: "t1" }).title, "(no title)");
    assertEquals(summarise({ id: "t1", title: "   " }).title, "(no title)");
});

// The desktop searches with the sentence the person said, and the task it
// filed earlier carries the draft's words, not the sentence.
Deno.test("a search matches by words, in title or notes, without regard to case", () => {
    const task = { title: "Send Deck to Alina", notes: "the pricing one" };
    assertEquals(matchScore(task, "I'll send the deck over to Alina tomorrow"), 3);
    assertEquals(matchScore(task, "DECK"), 1);
    assertEquals(matchScore(task, "pricing"), 1);
    assertEquals(matchScore(task, "invoice for September"), 0);
    assertEquals(matchScore({}, "deck"), 0);
});

Deno.test("a query of short words still asks for the whole phrase", () => {
    assertEquals(matchScore({ title: "Do it by Q3" }, "q3"), 1);
    assertEquals(matchScore({ title: "Do it by Q3" }, "q4"), 0);
    assertEquals(matchScore({ title: "anything" }, "   "), 0);
});

Deno.test("a repeated word counts once", () => {
    assertEquals(matchScore({ title: "deck" }, "deck deck deck"), 1);
});

// "the" and "over" would otherwise rank a stranger above a task sharing one
// real word with the question.
Deno.test("filler words do not score", () => {
    assertEquals(matchScore({ title: "Review the budget over lunch" }, "I'll send the deck over to Alina tomorrow"), 0);
    assertEquals(matchScore({ title: "Надіслати презентацію для Аліни" }, "треба надіслати презентацію про ціни"), 2);
    assertEquals(matchScore({ title: "the the the" }, "the"), 1);
});

// A Ukrainian keyboard types U+02BC where pasted text carries U+0027.
Deno.test("an apostrophe in either form is the same word", () => {
    assertEquals(matchScore({ title: "Полагодити комп\u02BCютер" }, "комп'ютер"), 1);
    assertEquals(matchScore({ title: "Полагодити комп'ютер" }, "комп\u02BCютер"), 1);
    assertEquals(matchScore({ title: "Полагодити комп\u2019ютер" }, "комп'ютер"), 1);
    assertEquals(matchScore({ title: "Don't forget the deck" }, "dont"), 1);
});

// Search ends at ten, and a recurring task's finished copies must not be the ten.
Deno.test("an open task outranks its finished twins", () => {
    const done = Array.from({ length: 11 }, (_, i) => ({
        id: `d${i}`,
        title: "Send weekly report",
        status: "completed",
        updated: `2026-08-${String(10 + i).padStart(2, "0")}T00:00:00.000Z`,
    }));
    const open = { id: "open", title: "Send weekly report", status: "needsAction", updated: "2026-01-01T00:00:00.000Z" };
    const ordered = orderedForSearch([...done, open], "send the weekly report");
    assertEquals(ordered[0].id, "open");
    assertEquals(ordered[1].id, "d10");
    assertEquals(ordered.length, 12);
});

Deno.test("a better match outranks an open one", () => {
    const ordered = orderedForSearch([
        { id: "a", title: "Send report", status: "needsAction" },
        { id: "b", title: "Send weekly report", status: "completed" },
    ], "send weekly report");
    assertEquals(ordered.map((task) => task.id), ["b", "a"]);
});

Deno.test("a new task carries its title and nothing it was not given", () => {
    assertEquals(newTask({ title: "  Send the deck " }), { title: "Send the deck" });
});

Deno.test("a new task carries notes under either name", () => {
    assertEquals(newTask({ title: "x", notes: " detail " }), { title: "x", notes: "detail" });
    assertEquals(newTask({ title: "x", description: "detail" }), { title: "x", notes: "detail" });
    assertEquals(newTask({ title: "x", notes: "  " }), { title: "x" });
});

Deno.test("a new task needs a title", () => {
    refused(() => newTask({}));
    refused(() => newTask({ title: "   " }));
    refused(() => newTask({ title: 7 }));
});

Deno.test("google's length limits are refused before the request", () => {
    refused(() => newTask({ title: "x".repeat(1025) }));
    assertEquals(newTask({ title: "x".repeat(1024) }).title?.length, 1024);
    refused(() => newTask({ title: "x", notes: "y".repeat(8193) }));
    refused(() => notesOf({ notes: 12 }));
    assertEquals(refused(() => notesOf({ description: 12 })).message, "`description` must be a string.");
});

// Google keeps only the date of a due timestamp and answers in UTC, so the
// calendar date the person named is sent as that date, whatever the offset.
Deno.test("a due timestamp becomes the day it names", () => {
    assertEquals(dueOf({ due: "2026-09-05T01:00:00+03:00" }), "2026-09-05T00:00:00.000Z");
    assertEquals(dueOf({ due: "2026-09-05T23:30:00-07:00" }), "2026-09-05T00:00:00.000Z");
    assertEquals(dueOf({ due: " 2026-09-05T00:00:00.000Z " }), "2026-09-05T00:00:00.000Z");
    assertEquals(newTask({ title: "x", due: "2026-09-05T09:00:00Z" }).due, "2026-09-05T00:00:00.000Z");
});

Deno.test("a bare due date becomes the timestamp google insists on", () => {
    assertEquals(dueOf({ due: "2026-09-05" }), "2026-09-05T00:00:00.000Z");
});

Deno.test("no due date is no due date", () => {
    assertEquals(dueOf({}), undefined);
    assertEquals(dueOf({ due: "" }), undefined);
    assertEquals(newTask({ title: "x", due: "" }), { title: "x" });
    assertEquals(newTask({ title: "x", due: null }), { title: "x" });
});

Deno.test("a due date google could not read is refused", () => {
    refused(() => dueOf({ due: "next thursday" }));
    refused(() => dueOf({ due: "Sep 5 2026" }));
    refused(() => dueOf({ due: "2026-13-45" }));
    refused(() => dueOf({ due: "2026-02-30" }));
    refused(() => dueOf({ due: "2026-09-31" }));
    refused(() => dueOf({ due: 20260905 }));
});

Deno.test("a status is one of google's two words", () => {
    assertEquals(statusOf({ status: "completed" }), "completed");
    assertEquals(statusOf({ status: "needsAction" }), "needsAction");
    refused(() => statusOf({ status: "done" }));
    refused(() => statusOf({ status: "COMPLETED" }));
    refused(() => statusOf({ status: true }));
});

// The desktop ticks a filed item with `closed`, as a string, like every tracker.
Deno.test("closed is the desktop's word for status", () => {
    assertEquals(statusOf({ closed: true }), "completed");
    assertEquals(statusOf({ closed: "true" }), "completed");
    assertEquals(statusOf({ closed: "false" }), "needsAction");
    refused(() => statusOf({ closed: "yes" }));
    assertEquals(statusOf({}), undefined);
});

Deno.test("an update patches only what was sent", () => {
    assertEquals(taskPatch({ key: "t1", title: "Renamed" }), { title: "Renamed" });
    assertEquals(taskPatch({ key: "t1", notes: "New notes" }), { notes: "New notes" });
    assertEquals(taskPatch({ key: "t1", due: "2026-09-05" }), { due: "2026-09-05T00:00:00.000Z" });
    assertEquals(taskPatch({ key: "t1", status: "completed" }), { status: "completed" });
    assertEquals(taskPatch({ key: "t1" }), {});
    assertEquals(taskPatch({ key: "t1", note: "appended elsewhere" }), {});
});

Deno.test("a null due date clears it", () => {
    assertEquals(taskPatch({ key: "t1", due: null }), { due: null });
    assertEquals(JSON.stringify(taskPatch({ key: "t1", due: null })), '{"due":null}');
});

// A blank would wipe what the person wrote.
Deno.test("empty notes on an update leave the notes alone", () => {
    assertEquals(taskPatch({ key: "t1", notes: "" }), {});
    assertEquals(taskPatch({ key: "t1", notes: "   " }), {});
});

// Google refuses `needsAction` while a completion stamp stands, and the
// clearing has to survive serialisation.
Deno.test("reopening clears the completion stamp", () => {
    assertEquals(taskPatch({ key: "t1", status: "needsAction" }), { status: "needsAction", completed: null });
    assertEquals(taskPatch({ key: "t1", closed: "false" }), { status: "needsAction", completed: null });
    assertEquals(taskPatch({ key: "t1", closed: "true" }), { status: "completed" });
    assertEquals(JSON.stringify(taskPatch({ key: "t1", closed: "false" })), '{"status":"needsAction","completed":null}');
});

Deno.test("an update refuses what a creation refuses", () => {
    refused(() => taskPatch({ key: "t1", title: "" }));
    refused(() => taskPatch({ key: "t1", title: "x".repeat(1025) }));
    refused(() => taskPatch({ key: "t1", due: "soon" }));
    refused(() => taskPatch({ key: "t1", status: "open" }));
});

Deno.test("a note is added below the notes that were there", () => {
    assertEquals(appended(undefined, "From today's call"), "From today's call");
    assertEquals(appended("   ", "From today's call"), "From today's call");
    assertEquals(appended("Spec", "From today's call"), "Spec\n\n---\n\nFrom today's call");
    refused(() => appended("x".repeat(8000), "y".repeat(200)));
});

Deno.test("an error remembers the provider's own status", () => {
    const error = new ActionError("provider_error", "gone", 502, undefined, 404);
    assertEquals(error.status, 502);
    assertEquals(error.providerStatus, 404);
    assertEquals(new ActionError("invalid_params", "x").providerStatus, undefined);
});
