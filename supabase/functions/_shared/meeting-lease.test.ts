import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { leaseConflictStatus, meetingIdFromPayload, transcribeLeasePayload } from "./meeting-lease.ts";

Deno.test("the meeting id is validated and stripped before the upstream call", () => {
    const parsed = transcribeLeasePayload({
        meeting_id: "123e4567-e89b-42d3-a456-426614174000",
        model: "whisper-1",
        input_audio: { data: "audio", format: "wav" },
    });

    assertEquals(parsed?.meetingId, "123e4567-e89b-42d3-a456-426614174000");
    assertEquals(parsed?.upstreamPayload, {
        model: "whisper-1",
        input_audio: { data: "audio", format: "wav" },
    });
    assertEquals("meeting_id" in (parsed?.upstreamPayload ?? {}), false);
});

Deno.test("malformed or absent ids are rejected", () => {
    assertEquals(meetingIdFromPayload({ meeting_id: "not-a-uuid" }), null);
    assertEquals(meetingIdFromPayload({}), null);
    assertEquals(transcribeLeasePayload({ model: "whisper-1" }), null);
});

Deno.test("a lease conflict never borrows the device-conflict status", () => {
    assertEquals(leaseConflictStatus("meeting_already_active"), 423);
    assertEquals(leaseConflictStatus("meeting_conflict"), 423);
    assertEquals(leaseConflictStatus("meeting_lease_ended"), 423);
    assertEquals(leaseConflictStatus("meeting_limit_reached"), 403);
});
