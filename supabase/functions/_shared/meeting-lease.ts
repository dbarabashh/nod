// A transcribe payload carries the meeting it belongs to so the proxy can check
// the recording's start lease. The id is ours, not the provider's — it is
// removed before the payload is forwarded upstream.

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export interface TranscribeLeasePayload {
    meetingId: string;
    upstreamPayload: Record<string, unknown>;
}

export function transcribeLeasePayload(payload: unknown): TranscribeLeasePayload | null {
    const meetingId = meetingIdFromPayload(payload);
    if (meetingId === null || !isObject(payload)) return null;
    const { meeting_id: _removed, ...upstreamPayload } = payload;
    return { meetingId, upstreamPayload };
}

export function meetingIdFromPayload(payload: unknown): string | null {
    if (!isObject(payload) || typeof payload.meeting_id !== "string") return null;
    return UUID_PATTERN.test(payload.meeting_id) ? payload.meeting_id : null;
}

// Lease refusals must never reuse 409: the client maps that status to the
// single-device lock and signs the user out. 423 keeps "someone else is
// recording" a recoverable, in-app message.
export function leaseConflictStatus(code: string): number {
    return code === "meeting_already_active"
        || code === "meeting_conflict"
        || code === "meeting_lease_ended"
        ? 423
        : 403;
}

function isObject(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}
