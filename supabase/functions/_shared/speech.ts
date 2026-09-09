import { modelFor } from "./models.ts";
// A spoken line: what Nod says after a question asked by voice.
//
// Two steps, two providers. `completeOnce` (OpenRouter, `_shared/complete.ts`)
// writes the words — short, in character, in the language the question was
// asked in. OpenAI's `/v1/audio/speech` (`gpt-4o-mini-tts`) then reads them,
// steered by an `instructions` string that describes how to say it — the one
// knob a chat-completions audio model doesn't expose, and the reason this
// isn't routed through OpenRouter like everything else.

export const SPEECH_MAX_CHARS = 1500;

// The languages Nod answers in (`AppLanguage`), which is also the set a
// caller may name. ISO 639-1 → the name the script-writing model is told.
export const SPEECH_LANGUAGES: Record<string, string> = {
    en: "English",
    zh: "Mandarin Chinese",
    hi: "Hindi",
    es: "Spanish",
    fr: "French",
    ar: "Arabic",
    bn: "Bengali",
    pt: "Portuguese",
    ru: "Russian",
    ur: "Urdu",
    de: "German",
    it: "Italian",
    uk: "Ukrainian",
    sr: "Serbian",
};

export const SCRIPT_MODEL = modelFor("speechScript");
// The proxy's own ceiling on what it will bill and speak, regardless of what
// the script-writing step returns — a runaway completion must not become a
// runaway TTS bill or a runaway wait.
export const SCRIPT_MAX_CHARS = 500;
export const TTS_MODEL = modelFor("tts");
// OpenAI's own recommendation for the two newest, most natural voices;
// cedar is the male one.
export const DEFAULT_VOICE = "cedar";

export type SpeechPurpose = "acknowledgement" | "answer" | "narration";

export interface SpeechRequest {
    text: string;
    language: string;
    purpose: SpeechPurpose;
    question: string;
    /// The text is already the line to say — no script step. A client uses
    /// it for lines it wrote itself, like the asides it keeps ready.
    verbatim: boolean;
    /// Answer as NDJSON, one clip per line, the first sentence on its own so
    /// it can play while the rest is still being synthesised.
    stream: boolean;
}

export interface SpeechRefusal {
    error: string;
    status: number;
}

// A short, already-plain answer needs no rephrasing — sending it to another
// model before it can be spoken is a whole network hop of pure latency for
// no gain. Anything that reads like it was written for a screen — markdown,
// a list, a link, a path, a bare identifier — still goes through the script
// step, which is exactly what strips that; only a short flat sentence goes
// straight to TTS.
export function looksAlreadySpoken(text: string): boolean {
    if (text.length > 220) return false;
    if (/[*_`#|\[\]]|(?:^|\n)\s*(?:[-+]|\d+[.)])\s/.test(text)) return false;
    if (/:\/\/|(?:^|\s)\/\S+\/\S*|\b[\w-]+\.(?:com|dev|app|io|org|net)\b/i.test(text)) return false;
    if (/\b[A-Za-z]{2,}-\d+\b|\b[0-9a-f]{8}\b/.test(text)) return false;
    return true;
}

export function speechRequest(payload: unknown): SpeechRequest | SpeechRefusal {
    if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
        return { error: "invalid_payload", status: 400 };
    }
    const { text, language, purpose, question, verbatim, stream } = payload as Record<string, unknown>;
    if (typeof text !== "string" || text.trim().length === 0) {
        return { error: "invalid_text", status: 400 };
    }
    if (text.length > SPEECH_MAX_CHARS) {
        return { error: "speech_too_long", status: 413 };
    }
    if (typeof language !== "string" || !(language in SPEECH_LANGUAGES)) {
        return { error: "invalid_language", status: 400 };
    }
    const kind: SpeechPurpose =
        purpose === "acknowledgement" ? "acknowledgement" : purpose === "narration" ? "narration" : "answer";
    const asked = typeof question === "string" ? question.slice(0, SPEECH_MAX_CHARS) : "";
    return {
        text: text.trim(),
        language,
        purpose: kind,
        question: asked,
        verbatim: verbatim === true,
        stream: stream === true,
    };
}

/// Whether the script step can be skipped: the caller vouched for the text,
/// or a short plain answer needs no rephrasing.
export function speaksAsWritten(request: SpeechRequest): boolean {
    // A vouched-for line is bounded like a plain one: the asides a client
    // keeps ready are a few words, and a patched client must not get the
    // voice to read a page under the same flag.
    return (request.verbatim && request.text.length <= VERBATIM_MAX_CHARS)
        || (request.purpose === "answer" && looksAlreadySpoken(request.text));
}

export const VERBATIM_MAX_CHARS = 220;

/// The script in the pieces it is synthesised in: the first sentence alone,
/// then everything after it. Two calls in flight at once, and the first is
/// the short one, so the voice starts on the opening sentence while the rest
/// is still being made. One piece when there is only one sentence.
export function speechChunks(script: string): string[] {
    const trimmed = script.trim();
    const match = trimmed.match(/^(.+?[.!?…]["'”’)]?)\s+(\S[\s\S]*)$/);
    // A first piece shorter than this is an abbreviation ("Dr.") or a word
    // ("Okay.") — not worth a round-trip of its own, and said with a pause
    // where none belongs.
    if (!match || match[1].length < 12) return [trimmed];
    return [match[1], match[2]];
}

export function isSpeechRefusal(value: SpeechRequest | SpeechRefusal): value is SpeechRefusal {
    return "error" in value;
}

// Who is talking. Not an assistant reading a result: the friend who sat in
// on the day and is easy to ask again.
const PERSONA =
    `You are Nod — the voice of a Mac app that sits in on the person's meetings, notes, calendar and ` +
    `screen, and remembers for them. You speak like a good friend who happened to be in the room: ` +
    `warm, relaxed, on their side, a little dry, never formal and never a customer-service voice. ` +
    `You use "you" and "I". You never say "as an AI", never apologise for being a program, never ` +
    `narrate your steps, and never read out anything that only makes sense on a screen — lists, ` +
    `headings, links, file names, paths, identifiers, code. Output only the words to say.`;

// A narration line is authored copy, not a question anyone asked — there is
// nothing to *decide* to say. But read verbatim it comes out in written
// register (full clauses, no contractions), which is exactly what makes a
// TTS voice sound like it's reading rather than talking. This case performs
// the same written-to-spoken pass an answer gets, holding the meaning and
// every literal button label or name fixed.
export function scriptPrompt(request: SpeechRequest): { system: string; user: string } {
    const language = SPEECH_LANGUAGES[request.language];
    if (request.purpose === "acknowledgement") {
        return {
            system: `${PERSONA} They just asked you something and the answer is on its way. Say what a ` +
                `friend says while turning to look — two to six words, in ${language}, natural and ` +
                `varied, never the same line twice. Name what you are checking only when the question ` +
                `makes it obvious (their calendar, a past meeting, what's on their screen, one of their ` +
                `tools); otherwise just let them know you're on it. Do not answer the question.`,
            user: `They asked: ${request.text}`,
        };
    }
    if (request.purpose === "narration") {
        return {
            system: `${PERSONA} You are given a line of already-approved onboarding copy. Say it in ` +
                `${language} the way you'd actually say it out loud to someone sitting next to you — ` +
                `contractions, natural rhythm, comfortable pauses — not read aloud the way it's punctuated. ` +
                `Keep every fact, instruction and literal button or field label exactly as given, and keep ` +
                `it to roughly the same length; you are re-voicing this line, not rewriting its meaning.`,
            user: `Line to say: ${request.text}`,
        };
    }
    return {
        system: `${PERSONA} You are given the question they asked by voice and the answer Nod wrote for ` +
            `them to read. Say the substance of that answer in ${language}, the way you'd say it across ` +
            `a desk, answer first. Match the length to the question: a quick question gets one short ` +
            `sentence — often just the fact — and only a question about a meeting, a session, a day's ` +
            `work or a brief earns two or three sentences with the details that matter — never more than ` +
            `about sixty words in all. Never pad, never recap the question, never list. Keep people's ` +
            `names, meeting titles and times; say numbers ` +
            `the way people say them. If the written answer asks them something, ask it. If it could not ` +
            `find what they wanted, say so in one honest sentence and, if it's obvious, what would help.`,
        user: `Question, as spoken:\n${request.question}\n\nAnswer, as written:\n${request.text}`,
    };
}

// The one knob `/v1/audio/speech` has that a chat-completions voice doesn't:
// a plain-language description of the performance, not just the words. The
// same person has to say both lines — most of this is shared on purpose, so
// the acknowledgement and the answer read as one continuous voice rather
// than two different takes with the volume or energy reset between them.
const VOICE_IDENTITY =
    "Voice: one specific person, a close and easygoing friend — warm, a little breathy, mid-range pitch, " +
    "never sharp, never shouty, never a narrator or a customer-service voice. " +
    "Delivery: real conversational pacing, natural contractions, the small breaths and micro-pauses of " +
    "someone actually talking rather than reading, a slight natural rise and fall in pitch, gentle emphasis " +
    "only on the one word that matters in the sentence. " +
    "Volume and energy: even and steady from the first word to the last — never trails off at the end, " +
    "never swells or raises into a shout, no dramatic jump in loudness or pace between sentences.";

export function speechInstructions(purpose: SpeechPurpose): string {
    switch (purpose) {
        case "acknowledgement":
            return `${VOICE_IDENTITY} This one line is a quick, warm aside — barely more energy than the ` +
                `answer that follows, like glancing over while already moving, not a separate performance.`;
        // Narration is the same person as every other line this voice ever
        // says — the first thing someone hears from Nod has to sound like
        // the same one they'll hear from every day after, not a separate
        // "tour guide" character who hands off to someone else once setup
        // is over.
        case "narration":
        case "answer":
            return `${VOICE_IDENTITY} This is the answer itself — unhurried, settled, like telling a friend ` +
                `something you're glad to report, in the same voice that just said the aside a moment ago.`;
    }
}

export function ttsBody(script: string, voice: string, purpose: SpeechPurpose): Record<string, unknown> {
    return {
        model: TTS_MODEL,
        voice,
        input: script,
        instructions: speechInstructions(purpose),
        // Not wav: a half-minute answer is 1.4 MB of PCM, base64'd into JSON
        // and downloaded whole before the first word plays — six seconds of
        // the wait on an ordinary connection. MP3 is a tenth of that, and
        // `AVAudioPlayer(data:)` on every shipped build plays it as it is.
        response_format: "mp3",
    };
}

// gpt-4o-mini-tts is billed per character, not reported per call; a flat
// per-character estimate is better than a blank cost column.
const USD_PER_CHAR = 0.000015;

export function ttsCostUsd(chars: number): number {
    return Math.round(USD_PER_CHAR * chars * 1_000_000) / 1_000_000;
}

// A real client says one acknowledgement and one answer per question. This
// is the ceiling above that, per user, so a patched client cannot turn the
// route into a narrator.
export const SPEECH_CALLS_PER_WINDOW = 40;
export const SPEECH_WINDOW_MS = 10 * 60 * 1000;

export class SpeechMeter {
    private counts = new Map<string, { n: number; since: number }>();

    allow(userId: string, now = Date.now()): boolean {
        if (this.counts.size > 1_000) this.sweep(now);
        const entry = this.counts.get(userId);
        if (!entry || now - entry.since >= SPEECH_WINDOW_MS) {
            this.counts.set(userId, { n: 1, since: now });
            return true;
        }
        if (entry.n >= SPEECH_CALLS_PER_WINDOW) return false;
        entry.n += 1;
        return true;
    }

    // Gives a slot back after a call this instance charged for turned out
    // to fail upstream — an outage should not spend a real user's abuse
    // budget the way an actual narrator would.
    refund(userId: string): void {
        const entry = this.counts.get(userId);
        if (entry && entry.n > 0) entry.n -= 1;
    }

    private sweep(now: number): void {
        for (const [userId, entry] of this.counts) {
            if (now - entry.since >= SPEECH_WINDOW_MS) this.counts.delete(userId);
        }
    }
}
