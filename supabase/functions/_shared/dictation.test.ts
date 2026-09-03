import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { DICTATION_MAX_SECONDS, dictationRefusal, wavSeconds } from "./dictation.ts";

interface Shape {
    sampleRate?: number;
    channels?: number;
    bits?: number;
}

function wav(seconds: number, { sampleRate = 16_000, channels = 1, bits = 16 }: Shape = {}): string {
    const pcmBytes = Math.round(seconds * sampleRate * channels * (bits / 8));
    const bytes = new Uint8Array(44 + pcmBytes);
    const view = new DataView(bytes.buffer);
    const put = (at: number, text: string) => [...text].forEach((c, i) => (bytes[at + i] = c.charCodeAt(0)));
    put(0, "RIFF");
    view.setUint32(4, 36 + pcmBytes, true);
    put(8, "WAVE");
    put(12, "fmt ");
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, channels, true);
    view.setUint32(24, sampleRate, true);
    view.setUint32(28, sampleRate * channels * (bits / 8), true);
    view.setUint16(32, channels * (bits / 8), true);
    view.setUint16(34, bits, true);
    put(36, "data");
    view.setUint32(40, pcmBytes, true);
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) {
        binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    }
    return btoa(binary);
}

function payload(data: string, format = "wav", extra: Record<string, unknown> = {}) {
    return { model: "whisper-1", input_audio: { data, format }, ...extra };
}

Deno.test("a short clip is allowed", () => {
    assertEquals(dictationRefusal(payload(wav(4))), null);
});

Deno.test("a clip at the cap is allowed and one over it is refused", () => {
    assertEquals(dictationRefusal(payload(wav(DICTATION_MAX_SECONDS))), null);
    assertEquals(dictationRefusal(payload(wav(DICTATION_MAX_SECONDS + 1))), {
        error: "dictation_too_long",
        status: 413,
    });
});

Deno.test("the cap is in seconds of the clip's own format, not bytes", () => {
    assertEquals(wavSeconds(wav(10, { sampleRate: 8_000, bits: 8 })), 10);
    assertEquals(wavSeconds(wav(10, { sampleRate: 48_000, channels: 2 })), 10);
    assertEquals(dictationRefusal(payload(wav(61, { sampleRate: 8_000, bits: 8 }))), {
        error: "dictation_too_long",
        status: 413,
    });
});

Deno.test("only wav is a dictation", () => {
    assertEquals(dictationRefusal(payload(wav(4), "ogg")), { error: "dictation_must_be_wav", status: 400 });
    assertEquals(dictationRefusal(payload(btoa("not a wav header at all, just text"))), {
        error: "invalid_audio",
        status: 400,
    });
});

Deno.test("a payload that names a meeting is not a dictation", () => {
    assertEquals(dictationRefusal(payload(wav(2), "wav", { meeting_id: "00000000-0000-4000-8000-000000000000" })), {
        error: "dictation_carries_no_meeting",
        status: 400,
    });
});

Deno.test("no audio, no dictation", () => {
    assertEquals(dictationRefusal({ model: "whisper-1" }), { error: "invalid_audio", status: 400 });
    assertEquals(dictationRefusal(null), { error: "invalid_payload", status: 400 });
    assertEquals(dictationRefusal([]), { error: "invalid_payload", status: 400 });
});
