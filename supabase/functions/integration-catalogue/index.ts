// integration-catalogue — names and draws the products a person has connected.
//
// Nod supports the products it has adapters for, and the catalogue is no longer
// something anybody browses. What is left is the half that was always load
// bearing: a connected product's own name and mark, for the rows that ship no
// asset of their own.
//
// The logo is proxied rather than linked. Everything else the desktop client
// does goes through an edge function, and a URL on the row would have the app
// fetch from a third party's CDN instead.
//
// Request  (POST /functions/v1/integration-catalogue): { "slugs": ["github", …] }
// Response: { "apps": [{ slug, name, description, categories }] }
//
// Request  (GET  /functions/v1/integration-catalogue?logo=<slug>)
// Response: the mark, with a long cache lifetime.
import { json } from "../_shared/http.ts";
import { authenticate } from "../_shared/supabase.ts";
import { appsURL, brokerGET, isConfigured } from "../_shared/integrations/pipedream.ts";

/// Slug → the catalogue's own mark, remembered from whatever result set carried
/// it. Bounded by what a session actually searched for.
const marks = new Map<string, string>();
// A mark changes about never, and the catalogue is walked a row at a time while
// somebody types.
const LOGO_CACHE_SECONDS = 60 * 60 * 24 * 30;
// Drawn at 17pt, so this covers a retina row with room to spare.
const LOGO_PIXELS = 96;

interface CatalogueApp {
    name_slug: string;
    name: string;
    description?: string | null;
    img_src?: string | null;
    categories?: string[] | null;
}

Deno.serve(async (req) => {
    if (!isConfigured) {
        console.error("pipedream connect is not configured");
        return json({ error: "Integrations unavailable" }, 503);
    }

    const url = new URL(req.url);
    const logo = url.searchParams.get("logo");
    if (req.method === "GET" && logo) return await serveLogo(logo);
    if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

    const auth = await authenticate(req);
    if (auth instanceof Response) return auth;

    const body = await req.json().catch(() => null);
    const slugs = Array.isArray(body?.slugs) ? (body.slugs as unknown[]).filter(isSlug) : [];

    const found = (await Promise.all(slugs.map(app)))
        .filter((entry): entry is CatalogueApp => entry !== null);

    const apps = found
        .map((app) => {
            if (typeof app.img_src === "string") marks.set(app.name_slug, app.img_src);
            return {
            slug: app.name_slug,
            name: app.name,
            // Catalogue copy is written for whoever is building an automation,
            // not for somebody deciding whether to hand over their account, so
            // it is a hint on the row rather than the promise our own products
            // make. First sentence only: the rest is API detail.
            description: firstSentence(app.description ?? ""),
            categories: (app.categories ?? []).slice(0, 2),
            };
        });

    return json({ apps }, 200);
});

function isSlug(value: unknown): value is string {
    return typeof value === "string" && /^[a-z0-9_-]+$/.test(value);
}

/// One app by slug. The resolve-by-slug path and the logo route both want
/// exactly this, and the guard belongs with the fetch rather than beside one of
/// its callers.
async function app(slug: string): Promise<CatalogueApp | null> {
    if (!isSlug(slug)) return null;
    const payload = await brokerGET(appsURL(`/${slug}`)) as { data?: CatalogueApp } | null;
    return payload?.data ?? null;
}

/// The broker's own mark for one app, passed through.
///
/// No authentication: it is a public logo, and requiring a JWT would mean the
/// row could not draw until the session was resolved. The slug is checked
/// against the catalogue rather than trusted, so this cannot be pointed at an
/// arbitrary host.
async function serveLogo(slug: string): Promise<Response> {
    // The search that produced this row already carried `img_src`; remembering
    // it there turns the common case from two upstream calls per icon into one.
    const source = marks.get(slug) ?? (await app(slug))?.img_src;
    if (typeof source !== "string") {
        return json({ error: "Unknown app" }, 404);
    }

    // The catalogue's own mark is the original upload — a quarter of a megabyte
    // of PNG for a 17pt row, forty rows to a search. The sized variant is the
    // same image at a fraction of it, and falling back keeps a product whose
    // upload has no variant from losing its mark entirely.
    const sized = source.replace(/\/orig$/, `/${LOGO_PIXELS}`);
    let image = await fetch(sized);
    if ((!image.ok || !image.body) && sized !== source) {
        // The refused response still holds a connection until its body is read
        // or cancelled, and retrying an identical URL only doubles the miss.
        await image.body?.cancel();
        image = await fetch(source);
    }
    if (!image.ok || !image.body) {
        console.warn(`catalogue logo fetch failed: ${slug} ${image.status}`);
        return json({ error: "No mark" }, 404);
    }

    return new Response(image.body, {
        status: 200,
        headers: {
            "Content-Type": image.headers.get("Content-Type") ?? "image/png",
            "Cache-Control": `public, max-age=${LOGO_CACHE_SECONDS}, immutable`,
        },
    });
}

/// The first sentence, or nothing. A catalogue description runs to a paragraph
/// of API surface, and a row has one line.
function firstSentence(text: string): string {
    const trimmed = text.trim();
    if (!trimmed) return "";
    const stop = trimmed.search(/\.\s/);
    const sentence = stop === -1 ? trimmed : trimmed.slice(0, stop + 1);
    return sentence.length > 140 ? `${sentence.slice(0, 137)}…` : sentence;
}
