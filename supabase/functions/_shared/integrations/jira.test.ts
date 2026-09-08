import { assertEquals } from "jsr:@std/assert@1.0.14";
import { browseURL, plainText, summarise } from "./jira.ts";

Deno.test("an issue link is the site's browse page, or nothing", () => {
    assertEquals(browseURL("https://acme.atlassian.net", "NOD-3"), "https://acme.atlassian.net/browse/NOD-3");
    assertEquals(browseURL("", "NOD-3"), undefined);
});

Deno.test("a document becomes the words in it, with block breaks", () => {
    const doc = {
        type: "doc",
        version: 1,
        content: [
            { type: "heading", attrs: { level: 2 }, content: [{ type: "text", text: "Pricing" }] },
            {
                type: "paragraph",
                content: [
                    { type: "text", text: "Pro goes to ", marks: [{ type: "strong" }] },
                    { type: "text", text: "$29" },
                    { type: "hardBreak" },
                    { type: "mention", attrs: { id: "1", text: "@Dima" } },
                    { type: "text", text: " to confirm" },
                ],
            },
            {
                type: "bulletList",
                content: [
                    { type: "listItem", content: [{ type: "paragraph", content: [{ type: "text", text: "monthly" }] }] },
                    { type: "listItem", content: [{ type: "paragraph", content: [{ type: "text", text: "yearly" }] }] },
                ],
            },
            { type: "mediaSingle", content: [{ type: "media", attrs: { id: "x" } }] },
        ],
    };
    assertEquals(plainText(doc), "Pricing\n\nPro goes to $29\n@Dima to confirm\n\n- monthly\n- yearly");
});

Deno.test("nothing in, nothing out", () => {
    assertEquals(plainText(null), "");
    assertEquals(plainText(undefined), "");
    assertEquals(plainText("legacy wiki text"), "");
});

// `closed` from the status category, never the status name: "Done", "Closed"
// and "Complete" are one thing to Nod.
Deno.test("a summary answers the task contract from the status category", () => {
    const issue = {
        key: "NOD-3",
        fields: {
            summary: "Ship it",
            updated: "2026-09-08T10:00:00.000+0000",
            status: { name: "Complete", statusCategory: { key: "done" } },
            assignee: { displayName: "Dima" },
        },
    };
    assertEquals(summarise(issue, "https://acme.atlassian.net"), {
        key: "NOD-3",
        title: "Ship it",
        url: "https://acme.atlassian.net/browse/NOD-3",
        closed: true,
        state: "Complete",
        assignee: "Dima",
        updated: "2026-09-08T10:00:00.000+0000",
    });
    assertEquals(summarise({ key: "NOD-4" }, ""), {
        key: "NOD-4",
        title: "",
        closed: false,
        state: undefined,
        assignee: null,
        updated: undefined,
    });
});
