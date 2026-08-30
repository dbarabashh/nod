// The one place that decides which model serves which job.
//
// Physical model ids used to be scattered across the Swift client and this
// function. The client still picks a default per task (it has to work offline
// from any server config), but the server is what gets to override it — and
// this table is the whole override surface. A model change is a secret change
// here, never a desktop release.
//
// `clientDefault` mirrors the defaults in `Nod/Core/LLM/LLMProxyClient.swift`.
// It is not decoration: a request carrying one of these ids is a stock client
// and may be re-routed, while anything else is an explicit user override
// (`defaults write com.example.nod openrouter.model …`) and is passed through
// untouched. Deriving the allow-list from this table is deliberate — the two
// used to be separate lists that had to be kept in sync by hand.

export const ROUTING_VERSION = "2026-08-v1";

type RoutingTask = "summary" | "title" | "utility" | "chat";

interface TaskPolicy {
    env: string;
    clientDefault: string;
}

const TASK_POLICY: Record<RoutingTask, TaskPolicy> = {
    summary: { env: "SUMMARY_MODEL", clientDefault: "anthropic/claude-sonnet-4.6" },
    title: { env: "TITLE_MODEL", clientDefault: "anthropic/claude-haiku-4.5" },
    utility: { env: "UTILITY_MODEL", clientDefault: "anthropic/claude-haiku-4.5" },
    chat: { env: "CHAT_MODEL", clientDefault: "anthropic/claude-sonnet-5" },
};

/// Every id a stock client can send, derived from the table above.
const CLIENT_DEFAULT_MODELS: ReadonlySet<string> = new Set(
    Object.values(TASK_POLICY).map((p) => p.clientDefault),
);

/// The policy model for this task, or undefined to leave the client's choice
/// alone. An unset variable is the "no policy" state, so an empty environment
/// reproduces pre-policy behavior exactly. `hasOwn` rather than `in`, so an
/// inherited name like "toString" can't be mistaken for a routing task.
function taskModelOverride(task: string): string | undefined {
    const policy = Object.hasOwn(TASK_POLICY, task) ? TASK_POLICY[task as RoutingTask] : undefined;
    return policy ? Deno.env.get(policy.env) : undefined;
}

/// Tasks whose reasoning is forced off, as a comma-separated `task` list
/// (`DISABLE_REASONING_TASKS=chat`). The client turns reasoning off for
/// `utility` alone and cannot be changed without a desktop release, so this is
/// the server-side lever for every other task. Measured on the sandbox chat
/// key over 30 days: 529k of 650k completion tokens were reasoning nobody read.
/// Unset is the "no policy" state, same as the model overrides above.
export function reasoningDisabled(task: string): boolean {
    const raw = Deno.env.get("DISABLE_REASONING_TASKS");
    return raw ? raw.split(",").some((entry) => entry.trim() === task) : false;
}

const MAX_FALLBACK_CHAIN = 3;

interface RoutedModel {
    payload: Record<string, unknown>;
    routed: string;
}

/// Swap in the policy model, keeping the client's own chain behind it so a bad
/// policy value degrades to today's behavior instead of failing the call.
export function applyModelPolicy(
    payload: Record<string, unknown>,
    task: string,
    requested: string,
): RoutedModel {
    const override = taskModelOverride(task);
    if (!override || override === requested || !CLIENT_DEFAULT_MODELS.has(requested)) {
        return { payload, routed: requested };
    }

    const clientChain = Array.isArray(payload.models) ? payload.models.filter((m) => typeof m === "string") : [];
    // OpenRouter rejects a `models` array longer than this outright (HTTP 400),
    // and the client already sends up to three, so prepending the policy model
    // has to drop the least-wanted tail rather than grow the chain.
    const chain = [override, ...clientChain.filter((m) => m !== override)].slice(0, MAX_FALLBACK_CHAIN);
    return { payload: { ...payload, model: override, models: chain }, routed: override };
}

// STT is routed by provider order rather than by model id — the model is the
// same Whisper large-v3 either way, only the control plane differs.
type SttRoutingMode = "groq_primary" | "openrouter_primary" | "openrouter_only";

export function sttRoutingMode(): SttRoutingMode {
    const raw = Deno.env.get("STT_ROUTING_MODE");
    if (raw === "openrouter_primary" || raw === "openrouter_only") return raw;
    return "groq_primary";
}

// Anthropic and Google bill explicit cache writes; OpenAI caches automatically
// and rejects the marker, so a model routed to it must not carry one.
const CACHEABLE_MODEL_PREFIXES = ["anthropic/", "google/"];

export function supportsExplicitPromptCache(model: unknown): boolean {
    return typeof model === "string" && CACHEABLE_MODEL_PREFIXES.some((p) => model.startsWith(p));
}
