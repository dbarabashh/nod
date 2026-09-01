// Turning the person a proposal names into the account the provider knows.
//
// Kept out of `index.ts` because it is the only part of executing a proposal
// that is about people rather than about state, and because it is where the
// identity table earns its place: a `people.id` means nothing to Linear, and a
// name means nothing to anybody.
//
// The directory is normally already here — connecting a tool imports its member
// list — so this is the fallback for the two cases that misses: a connection
// made before the organization existed, and somebody who joined the workspace
// since. Reading it again costs one call and answers for everybody at once.
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { ActionError, type Connection } from "../_shared/integrations/pipedream.ts";
import { importDirectory } from "../_shared/integrations/directory.ts";

export interface Proposal {
    id: string;
    org_id: string | null;
    action_item_id: string | null;
    type: string;
    status: string;
    parameters: Record<string, unknown>;
}

/// The provider's own id for the person this proposal assigns to, or null when
/// it assigns to nobody.
///
/// Throws rather than silently dropping the assignment when a person was named
/// and cannot be reached: a ticket that quietly lands unassigned looks exactly
/// like one that was never meant to have an owner, and the difference is the
/// whole point of having asked.
export async function resolveAssignee(
    admin: SupabaseClient,
    connection: Connection,
    proposal: Proposal,
): Promise<string | null> {
    const personId = proposal.parameters.assignee_person_id;
    if (typeof personId !== "string" || !personId) return null;

    const provider = connection.provider;

    const known = await identityFor(admin, personId, provider);
    if (known) return known;

    // Never across organizations. A proposal raised inside one company must not
    // be able to name somebody from another, however the id got into it.
    const { data: person } = await admin
        .from("people")
        .select("primary_email, display_name, org_id")
        .eq("id", personId)
        .is("deleted_at", null)
        .maybeSingle<{ primary_email: string | null; display_name: string | null; org_id: string }>();

    if (!person || !proposal.org_id || person.org_id !== proposal.org_id) {
        throw new ActionError("unknown_person", "That person is not in this organization.", 403);
    }
    if (!person.primary_email) {
        throw new ActionError(
            "no_identity",
            `Nod has no address for ${person.display_name ?? "that person"}, so it cannot find them in ${provider}.`,
        );
    }

    // Not scoped to administrators, unlike the automatic import: this runs
    // because somebody is assigning work inside their own organization, which is
    // already a statement that this workspace is the company's.
    await importDirectory(admin, connection, person.org_id);

    const learned = await identityFor(admin, personId, provider);
    if (!learned) {
        throw new ActionError(
            "no_identity",
            `${person.display_name ?? person.primary_email} has no ${provider} account Nod can see.`,
        );
    }
    return learned;
}

async function identityFor(
    admin: SupabaseClient,
    personId: string,
    provider: string,
): Promise<string | null> {
    const { data } = await admin
        .from("person_identities")
        .select("external_id")
        .eq("person_id", personId)
        .eq("provider", provider)
        .maybeSingle<{ external_id: string }>();
    return data?.external_id ?? null;
}
