export class UpstreamRateLimit extends Error {
    constructor(readonly retryAfterSeconds: number) {
        super("upstream rate limited");
    }
}

export function retryAfterSeconds(header: string | null, now = Date.now()): number {
    if (!header?.trim()) return 60;
    const numeric = Number(header);
    const seconds = Number.isFinite(numeric) ? numeric : (Date.parse(header) - now) / 1000;
    return Number.isFinite(seconds) ? Math.max(1, Math.ceil(seconds)) : 60;
}
