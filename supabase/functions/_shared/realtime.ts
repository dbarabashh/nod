import { modelFor } from "./models.ts";
// A live voice session: OpenAI's Realtime API, over a WebSocket the client
// holds itself. This proxy's one job is to mint the short-lived credential
// that lets it do that without ever holding the real API key — the same
// shape as every other secret in this app, just handed out per session
// instead of per call.

export const REALTIME_MODEL = modelFor("realtime");
export const REALTIME_DEFAULT_VOICE = "cedar";
// Long enough to cover a real conversation's connect handshake and any
// retry, short enough that a leaked token is worthless within the hour.
export const REALTIME_TOKEN_TTL_SECONDS = 600;

// Who is talking — the same friend the two-step voice-ask design used,
// carried over so the live session reads as the same person.
export const REALTIME_PERSONA =
    "You are Nod — the voice of a Mac app that sits in on the person's meetings, notes, calendar and " +
    "screen, and remembers for them. You speak like a good friend who happened to be in the room: warm, " +
    "relaxed, on their side, a little dry, never formal and never a customer-service voice. You use " +
    "\"you\" and \"I\". You never say \"as an AI\", never apologise for being a program, never narrate " +
    "your steps, and never read anything aloud that only makes sense on a screen — lists, headings, " +
    "links, file names, paths, identifiers, code. Answer first, then keep going only if it earns its " +
    "place: a quick question gets one short sentence; a question about a meeting, a session, a day's " +
    "work or a brief earns two or three sentences with the details that matter. This is a live " +
    "conversation, not a monologue — if they cut in, stop and listen. " +
    // The session opens on a bare tap, which is also how it opens by accident.
    // Greeting an empty room is the difference between a tool and a nuisance.
    "You never speak first. The session opens silently and you wait: say nothing at all — no greeting, " +
    "no offer of help, not a word — until the person has spoken to you.";

export interface RealtimeTokenRequest {
    language?: string;
    /// What to call the person. Bounded: it lands in the instructions verbatim.
    name?: string;
}

export function realtimeTokenRequest(payload: unknown): RealtimeTokenRequest {
    if (typeof payload !== "object" || payload === null || Array.isArray(payload)) return {};
    const { language, name } = payload as Record<string, unknown>;
    const request: RealtimeTokenRequest = {};
    if (typeof language === "string") request.language = language;
    if (typeof name === "string" && name.trim() && name.trim().length <= 60) request.name = name.trim();
    return request;
}

export function realtimeInstructions(request: RealtimeTokenRequest): string {
    const parts = [REALTIME_PERSONA];
    if (request.name) {
        parts.push(`The person you're talking to is ${request.name}; use their name the way a friend would, sometimes and not every turn.`);
    }
    if (request.language) {
        parts.push(`Speak the language the person speaks to you in; ${request.language} is the one to answer in until they show you otherwise.`);
    }
    return parts.join(" ");
}

// The one thing the live model is told about the person's own data: how to
// ask for it. Everything it can actually answer with — sessions, calendar,
// beats, tasks, projects, the screen record — lives behind this single call,
// answered by the same grounded pipeline typed and held-key questions use.
// One tool, not one per data source: the routing and retrieval this already
// does is exactly what a second, duplicated tool schema would have to redo.
const ASK_NOD_TOOL = {
    type: "function",
    name: "ask_nod",
    description:
        "Ask Nod anything about the user's own recorded meetings and voice notes, calendar, open tasks, " +
        "projects, scheduled agents (called beats in earlier builds), or what has recently been on " +
        "their screen. Call this before answering " +
        "any question that depends on the user's own day, work, schedule, or recordings — you have no " +
        "knowledge of these on your own. Pass the question close to how they asked it.",
    parameters: {
        type: "object",
        properties: {
            question: { type: "string", description: "The question, in the user's own words." },
        },
        required: ["question"],
    },
};

// Non-mutating "open" — nothing here changes any of the user's data, which
// is what lets it run without the approval card every write elsewhere in
// this app goes through (see `ChatToolGate`). The description is the only
// thing standing between this and the model opening a page it invented;
// `open_url` is deliberately not told it may guess.
const OPEN_URL_TOOL = {
    type: "function",
    name: "open_url",
    description:
        "Opens a web link in the user's default browser. Use it when the user asks to open something ask_nod " +
        "just found for them (a Linear issue, an email thread, a calendar event, a document) or a page they " +
        "named directly. Only pass a URL you actually have — from ask_nod's own answer, or one the user said " +
        "themselves. Never invent, guess, or complete a URL from a company or product name.",
    parameters: {
        type: "object",
        properties: {
            url: { type: "string", description: "The exact http(s) URL to open, verbatim." },
        },
        required: ["url"],
    },
};

const OPEN_APP_TOOL = {
    type: "function",
    name: "open_app",
    description:
        "Opens an application already installed on the user's Mac, by name — e.g. \"Slack\", \"Mail\", " +
        "\"Finder\", \"System Settings\". Use it when the user asks to open, switch to, or launch an app. Not " +
        "for opening a document, a website, or a file — those go through open_url or aren't supported.",
    parameters: {
        type: "object",
        properties: {
            name: { type: "string", description: "The application's name, as the user said it." },
        },
        required: ["name"],
    },
};

export function realtimeSessionBody(request: RealtimeTokenRequest, voice: string): Record<string, unknown> {
    return {
        expires_after: { anchor: "created_at", seconds: REALTIME_TOKEN_TTL_SECONDS },
        session: {
            type: "realtime",
            model: REALTIME_MODEL,
            instructions: realtimeInstructions(request),
            output_modalities: ["audio"],
            audio: {
                input: { format: { type: "audio/pcm", rate: 24_000 }, turn_detection: { type: "server_vad" } },
                output: { format: { type: "audio/pcm", rate: 24_000 }, voice },
            },
            tools: [ASK_NOD_TOOL, OPEN_URL_TOOL, OPEN_APP_TOOL],
            tool_choice: "auto",
        },
    };
}

// A live session costs real per-minute money and the proxy never sees the
// call-by-call usage a REST hop would report — so unlike `speak`, the limit
// here bounds how often a session may be *started*, not how long one runs.
export const REALTIME_SESSIONS_PER_WINDOW = 20;
export const REALTIME_WINDOW_MS = 60 * 60 * 1000;

export class RealtimeSessionMeter {
    private counts = new Map<string, { n: number; since: number }>();

    allow(userId: string, now = Date.now()): boolean {
        if (this.counts.size > 1_000) this.sweep(now);
        const entry = this.counts.get(userId);
        if (!entry || now - entry.since >= REALTIME_WINDOW_MS) {
            this.counts.set(userId, { n: 1, since: now });
            return true;
        }
        if (entry.n >= REALTIME_SESSIONS_PER_WINDOW) return false;
        entry.n += 1;
        return true;
    }

    // Every failure to mint a token is a network or upstream issue, never
    // something the caller's own input provoked — `realtimeTokenRequest`
    // accepts nothing but a language hint, so there is no content here that
    // could be shaped to trip a refund on purpose the way a TTS script could.
    refund(userId: string): void {
        const entry = this.counts.get(userId);
        if (entry && entry.n > 0) entry.n -= 1;
    }

    private sweep(now: number): void {
        for (const [userId, entry] of this.counts) {
            if (now - entry.since >= REALTIME_WINDOW_MS) this.counts.delete(userId);
        }
    }
}
