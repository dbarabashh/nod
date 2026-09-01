// HubSpot, over its CRM v3 API.
//
// Reads, plus one narrow write: logging a note on a record, on the person's own
// instruction and behind the desktop's approval card. Deliberately nothing
// else — writing a deal stage from a conversation would be Nod changing a
// number somebody's forecast depends on, and a note is the one CRM write that
// only ever adds context.
//
// Every result is trimmed to what a model needs to answer or to cite. A HubSpot
// record carries hundreds of properties; asking for the four that matter is the
// difference between a usable turn and a wasted one.
import { ActionError, type Connection, proxy } from "./pipedream.ts";
import type { ActionHandlers } from "./registry.ts";
import { requireString } from "./params.ts";

const LIMIT = 10;

interface Record_ {
    id?: string;
    properties?: Record<string, string | null>;
}


/// A free-text search over one object type.
///
/// `query` rather than `filterGroups`: the caller has a name somebody said out
/// loud, not a property and an operator, and HubSpot's own free-text search is
/// what turns one into the other.
async function search(
    connection: Connection,
    object: string,
    query: string,
    properties: string[],
): Promise<Record_[]> {
    const payload = await proxy(connection, `crm/v3/objects/${object}/search`, {
        query,
        properties,
        limit: LIMIT,
    }) as { results?: Record_[] } | null;
    return payload?.results ?? [];
}

/// The record's own page, which is the only part of a CRM answer a person can
/// check. HubSpot search returns no url, and it is derivable from the id.
function link(portal: string | undefined, object: string, id: string | undefined): string | undefined {
    return portal && id ? `https://app.hubspot.com/contacts/${portal}/${object}/${id}` : undefined;
}

/// Which HubSpot account this connection belongs to, for building those links.
/// Cached per account id, because it never changes and every answer wants it.
/// `undefined` is cached too: an account whose token answers without a portal
/// id will never grow one, and re-asking on every lookup buys a wasted round
/// trip per CRM answer for the life of the instance.
const portals = new Map<string, string | undefined>();

async function portalID(connection: Connection): Promise<string | undefined> {
    if (portals.has(connection.id)) return portals.get(connection.id);
    const payload = await proxy(connection, "account-info/v3/details", null, { method: "GET" }) as
        { portalId?: number } | null;
    const id = payload?.portalId ? String(payload.portalId) : undefined;
    portals.set(connection.id, id);
    return id;
}

/// The names a record answers to, per type — what `find_*` showed the person.
const NAME_PROPERTIES: Record<string, string[]> = {
    contact: ["firstname", "lastname", "email"],
    company: ["name", "domain"],
    deal: ["dealname"],
};

/// The objects API speaks plurals, and English pluralises `company` its own
/// way — `${object}s` produced `companys`, which HubSpot cannot infer a type
/// from, and every company note was refused before the write.
const OBJECT_PATHS: Record<string, string> = {
    contact: "contacts",
    company: "companies",
    deal: "deals",
};

/// Refuses a `record_id` whose live record is not the one named on the
/// approval card. The card shows a name while the wire carries an id, and
/// nothing else stops a model from logging a meeting summary onto the wrong
/// company's record.
async function assertRecordNamed(
    connection: Connection,
    object: string,
    recordId: string,
    expected: string,
): Promise<void> {
    const record = await proxy(connection, `crm/v3/objects/${OBJECT_PATHS[object]}/${recordId}`, null, {
        method: "GET",
        query: { properties: NAME_PROPERTIES[object].join(",") },
    }) as Record_ | null;
    if (!record?.id) {
        throw new ActionError("provider_error", "HubSpot did not return that record.", 502);
    }

    const wanted = expected.trim().toLowerCase();
    const names = [
        ...NAME_PROPERTIES[object].map((property) => record.properties?.[property] ?? ""),
        [record.properties?.firstname, record.properties?.lastname].filter(Boolean).join(" "),
    ].map((name) => name.trim().toLowerCase()).filter(Boolean);
    if (!names.includes(wanted)) {
        throw new ActionError(
            "invalid_params",
            `That ${object} is "${names[0] ?? "unnamed"}", not "${expected}". Find it again and use the id next to the right name.`,
        );
    }
}

/// HubSpot's fixed ids for "this note belongs to that record", one per record
/// type. HUBSPOT_DEFINED, so they are the same in every portal.
const NOTE_ASSOCIATIONS: Record<string, number> = {
    contact: 202,
    company: 190,
    deal: 214,
};

export const HUBSPOT_ACTIONS: ActionHandlers = {
    find_company: async (connection, params) => {
        const name = requireString(params, "name");
        const [records, portal] = await Promise.all([
            search(connection, "companies", name, ["name", "domain", "industry", "hs_lastmodifieddate"]),
            portalID(connection),
        ]);

        return {
            companies: records.map((record) => ({
                id: record.id,
                name: record.properties?.name,
                domain: record.properties?.domain,
                industry: record.properties?.industry,
                updated: record.properties?.hs_lastmodifieddate,
                url: link(portal, "company", record.id),
            })),
        };
    },

    find_contact: async (connection, params) => {
        const query = requireString(params, "query");
        const [records, portal] = await Promise.all([
            search(connection, "contacts", query, ["firstname", "lastname", "email", "jobtitle", "company"]),
            portalID(connection),
        ]);

        return {
            contacts: records.map((record) => ({
                id: record.id,
                name: [record.properties?.firstname, record.properties?.lastname]
                    .filter(Boolean).join(" ") || record.properties?.email,
                email: record.properties?.email,
                title: record.properties?.jobtitle,
                company: record.properties?.company,
                url: link(portal, "contact", record.id),
            })),
        };
    },

    /// Deals matching a name, with the two fields anybody asks about.
    ///
    /// `dealstage` is the pipeline's own id, not its label — HubSpot names
    /// stages per pipeline and resolving them is a second round trip for a
    /// string the model would only read back. The amount and close date are
    /// what "where did it get to" actually means.
    find_deals: async (connection, params) => {
        const query = requireString(params, "query");
        const [records, portal] = await Promise.all([
            search(connection, "deals", query, ["dealname", "amount", "dealstage", "closedate"]),
            portalID(connection),
        ]);

        return {
            deals: records.map((record) => ({
                id: record.id,
                name: record.properties?.dealname,
                amount: record.properties?.amount,
                stage: record.properties?.dealstage,
                closes: record.properties?.closedate,
                url: link(portal, "deal", record.id),
            })),
        };
    },

    /// Logs one note on a company, contact or deal.
    create_note: async (connection, params) => {
        const body = requireString(params, "body");
        const attachTo = requireString(params, "attach_to");
        const recordId = requireString(params, "record_id");
        const association = NOTE_ASSOCIATIONS[attachTo];
        if (!association) {
            throw new ActionError(
                "invalid_params",
                `\`attach_to\` must be one of ${Object.keys(NOTE_ASSOCIATIONS).join(", ")}.`,
            );
        }
        if (!/^\d+$/.test(recordId)) {
            throw new ActionError("invalid_params", "`record_id` must be an id from a find result.");
        }
        await assertRecordNamed(connection, attachTo, recordId, requireString(params, "record_name"));

        // The write goes first, alone. Racing it against the portal lookup
        // would let a failed lookup report a note that was in fact created —
        // and the retry that follows logs it twice.
        const note = await proxy(connection, "crm/v3/objects/notes", {
            properties: { hs_note_body: body, hs_timestamp: new Date().toISOString() },
            associations: [{
                to: { id: recordId },
                types: [{ associationCategory: "HUBSPOT_DEFINED", associationTypeId: association }],
            }],
        }) as Record_ | null;
        if (!note?.id) {
            throw new ActionError("provider_error", "HubSpot did not return the created note.", 502);
        }

        const portal = await portalID(connection).catch(() => undefined);
        return { id: note.id, attached_to: link(portal, attachTo, recordId) };
    },
};
