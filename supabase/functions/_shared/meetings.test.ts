import { capTranscriptPage, parseTranscriptCursor, type TranscriptLine } from "./meetings.ts";

function lines(count: number, text = "segment"): TranscriptLine[] {
    return Array.from({ length: count }, (_, idx) => ({ source: "them", text, idx, ts: String(idx) }));
}

Deno.test("transcript page exposes a continuation cursor", () => {
    const page = capTranscriptPage(lines(101), 100);
    if (page.lines.length !== 100) throw new Error("expected 100 transcript segments");
    if (page.nextCursor !== "99") throw new Error("expected the last returned index as cursor");
    if (page.characterLimited) throw new Error("unexpected character limit");
});

Deno.test("transcript page never exceeds the character cap", () => {
    const page = capTranscriptPage(lines(2, "x".repeat(100_000)), 100);
    const characters = page.lines.reduce((total, line) => total + line.source.length + line.text.length + 2, 0);
    if (characters > 100_000) throw new Error("transcript exceeded 100,000 characters");
    if (!page.characterLimited) throw new Error("expected character limit marker");
    if (page.nextCursor !== "0") throw new Error("expected continuation after the truncated segment");
});

Deno.test("transcript cursor accepts only non-negative integer strings", () => {
    if (parseTranscriptCursor(undefined) !== null) throw new Error("expected an absent cursor");
    if (parseTranscriptCursor("0") !== 0) throw new Error("expected zero cursor");
    if (parseTranscriptCursor("123") !== 123) throw new Error("expected numeric cursor");
    for (const cursor of ["-1", "1.5", "123abc", "abc"]) {
        try {
            parseTranscriptCursor(cursor);
            throw new Error(`expected ${cursor} to be rejected`);
        } catch (error) {
            if (!(error instanceof Error) || error.message !== "Invalid transcript cursor") throw error;
        }
    }
});
