import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert";
import { draftMIME, headerValue } from "./gmail.ts";

Deno.test("an ascii subject travels as itself", () => {
    assertEquals(headerValue("Follow-up on pricing"), "Follow-up on pricing");
});

// A bare Ukrainian subject would arrive mangled without RFC 2047.
Deno.test("a non-ascii subject is RFC 2047 encoded", () => {
    const encoded = headerValue("Оновити платіжку");
    assert(encoded.startsWith("=?UTF-8?B?") && encoded.endsWith("?="));
    const decoded = new TextDecoder().decode(
        Uint8Array.from(atob(encoded.slice(10, -2)), (c) => c.charCodeAt(0)),
    );
    assertEquals(decoded, "Оновити платіжку");
});

Deno.test("the draft carries headers, base64 body, and CRLF lines", () => {
    const mime = draftMIME(["a@x.com"], ["b@x.com"], "Hi", "Привіт!\nДо зустрічі.");
    assertStringIncludes(mime, "To: a@x.com\r\nCc: b@x.com\r\nSubject: Hi\r\n");
    assertStringIncludes(mime, "Content-Transfer-Encoding: base64\r\n\r\n");
    const body = mime.split("\r\n\r\n")[1];
    const decoded = new TextDecoder().decode(
        Uint8Array.from(atob(body), (c) => c.charCodeAt(0)),
    );
    assertEquals(decoded, "Привіт!\nДо зустрічі.");
});

// The exact injection this guards: a CR-LF in an all-ASCII subject would end
// the Subject line and let what follows pose as a Bcc header.
Deno.test("a control character in a subject is neutralised by encoding", () => {
    const smuggled = "Quick note\r\nBcc: attacker@evil.com";
    const encoded = headerValue(smuggled);
    assert(encoded.startsWith("=?UTF-8?B?"));
    const mime = draftMIME(["a@x.com"], [], smuggled, "hi");
    assertEquals(mime.split("\r\n").filter((line) => line.startsWith("Bcc")).length, 0);
});

Deno.test("a reply carries the original's Message-ID", () => {
    const mime = draftMIME(["a@x.com"], [], "Re: Hi", "ok", "<abc@mail.gmail.com>");
    assertStringIncludes(mime, "In-Reply-To: <abc@mail.gmail.com>\r\nReferences: <abc@mail.gmail.com>\r\n");
});

// RFC 2045 caps encoded lines at 76 characters.
Deno.test("a long body folds into legal line lengths", () => {
    const mime = draftMIME(["a@x.com"], [], "Hi", "x".repeat(9000));
    const body = mime.split("\r\n\r\n")[1];
    assert(body.split("\r\n").every((line) => line.length <= 76));
    const decoded = new TextDecoder().decode(
        Uint8Array.from(atob(body.split("\r\n").join("")), (c) => c.charCodeAt(0)),
    );
    assertEquals(decoded, "x".repeat(9000));
});
