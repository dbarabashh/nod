// HubSpot, over its CRM v3 API.
//
// Read-only. The question a meeting asks a CRM is "have we talked to these
// people before, and where did it get to" — and that is the whole of it. Writing
// a deal stage from a conversation would be Nod changing a number somebody's
// forecast depends on.
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
};
