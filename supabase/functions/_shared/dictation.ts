// A held-key question: one clip, no meeting behind it. It rides the transcribe
// path but presents no lease, so the only thing standing between a caller and
// an hour of audio on a provider's bill is this cap — measured in seconds of
// the clip's own format, since a byte count says nothing about a codec the
// caller picked.

export const DICTATION_MAX_SECONDS = 60;

export interface DictationRefusal {
    error: string;
    status: number;
}

// Null when the clip may be transcribed; otherwise the response to send back.
export function dictationRefusal(payload: unknown): DictationRefusal | null {
    if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
        return { error: "invalid_payload", status: 400 };
    }
    if ("meeting_id" in payload) {
        return { error: "dictation_carries_no_meeting", status: 400 };
    }
    const audio = (payload as Record<string, unknown>).input_audio;
    if (typeof audio !== "object" || audio === null || Array.isArray(audio)) {
        return { error: "invalid_audio", status: 400 };
    }
    const { data, format } = audio as Record<string, unknown>;
    if (format !== "wav" || typeof data !== "string") {
        return { error: "dictation_must_be_wav", status: 400 };
    }
    const seconds = wavSeconds(data);
    if (seconds === null || seconds <= 0) {
        return { error: "invalid_audio", status: 400 };
    }
    if (seconds > DICTATION_MAX_SECONDS) {
        return { error: "dictation_too_long", status: 413 };
    }
    return null;
}

const WAV_HEADER_BYTES = 44;

// The duration a canonical 44-byte-header PCM WAV describes, from its own
// format chunk — sample rate, channels and bit depth are read, not assumed.
export function wavSeconds(base64: string): number | null {
    if (base64.length < 60) return null;
    let head: Uint8Array;
    try {
        head = Uint8Array.from(atob(base64.slice(0, 60)), (c) => c.charCodeAt(0));
    } catch {
        return null;
    }
    const view = new DataView(head.buffer);
    const tag = (at: number) => String.fromCharCode(...head.subarray(at, at + 4));
    if (tag(0) !== "RIFF" || tag(8) !== "WAVE" || tag(12) !== "fmt " || tag(36) !== "data") return null;
    const channels = view.getUint16(22, true);
    const sampleRate = view.getUint32(24, true);
    const bitsPerSample = view.getUint16(34, true);
    const bytesPerSecond = sampleRate * channels * (bitsPerSample / 8);
    if (!(bytesPerSecond > 0)) return null;
    const padding = base64.endsWith("==") ? 2 : base64.endsWith("=") ? 1 : 0;
    const byteCount = Math.floor((base64.length * 3) / 4) - padding;
    const pcmBytes = Math.max(0, byteCount - WAV_HEADER_BYTES);
    return pcmBytes / bytesPerSecond;
}
