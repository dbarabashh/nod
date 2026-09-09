// The error every adapter and every door throws.
//
// Its own module so that `pipedream.ts` — which resolves a connection and
// therefore has to ask `policy.ts` whether one may be held — and `policy.ts`,
// which throws this, do not import each other. The cycle would resolve at
// runtime and break the first time either file referenced the other at module
// scope; a separate module means the question never comes up.
export class ActionError extends Error {
    readonly code: string;
    readonly status: number;
    /// The provider's own word for what went wrong, when there was one.
    ///
    /// `code` is ours and `message` is the person's; neither survives the trip
    /// from a provider intact, and an adapter that wants to recover from one
    /// specific failure — Slack's `not_in_channel`, say — has nothing else to
    /// match on. Every adapter hits this eventually, so it belongs here rather
    /// than being cast onto the error at one throw site.
    readonly providerCode?: string;
    /// The HTTP status the provider answered with, when the error is one.
    ///
    /// `status` is what we answer the client and is always 502 for a refused
    /// proxy call; an adapter that wants to treat "gone" differently from
    /// "throttled" needs the provider's own number.
    readonly providerStatus?: number;

    constructor(code: string, message: string, status = 400, providerCode?: string, providerStatus?: number) {
        super(message);
        this.code = code;
        this.status = status;
        this.providerCode = providerCode;
        this.providerStatus = providerStatus;
    }
}
