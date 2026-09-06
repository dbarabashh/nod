import { assertEquals } from "jsr:@std/assert@1.0.14";
import { plainText } from "./jira.ts";

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
