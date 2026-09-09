// Learning who works at a company from the tools they already use.
//
// The reason this exists is onboarding. Inviting every colleague into Nod before
// a meeting can assign anything to any of them is an afternoon of work standing
// between somebody and the first thing the product does — and the list already
// exists, in whatever tracker and whatever chat that company runs on, kept
// accurate by the fact that people are removed from those when they leave.
//
// Nothing here knows a product's name. A provider is a directory source if its
// adapter answers `list_users` with `{ id, name, email }`, and adding Jira or
// Teams is that one handler plus a row in the registry.
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { type Connection } from "./pipedream.ts";
import { handlerFor } from "./registry.ts";

export interface WorkspaceMember {
    id: string;
    name?: string;
    email?: string;
}

export interface ImportOutcome {
    /// Workspace members the provider reported and we could use.
    seen: number;
    /// People now addressable in this provider as a result.
    linked: number;
}

/// Whether a provider can answer who is in the workspace.
export function isDirectorySource(provider: string): boolean {
    return handlerFor(provider, "list_users") !== undefined;
}

/// Reads a connected workspace's member list and writes it into the
/// organization's people.
///
/// Idempotent and safe to run on every connection: matching is by address,
/// creating is only for addresses the organization has never seen, and a name
/// somebody set for themselves is never replaced by a workspace's rendering of
/// it. Re-running after somebody leaves the workspace does not remove them —
/// the record is what the audit log and past meetings refer to, and a person who
/// left is exactly who a question about last quarter is about.
export async function importDirectory(
    admin: SupabaseClient,
    connection: Connection,
    orgId: string,
): Promise<ImportOutcome> {
    const list = handlerFor(connection.provider, "list_users");
    if (!list) return { seen: 0, linked: 0 };

    const result = await list(connection, {}) as { users?: WorkspaceMember[] };
    // An address is the only thing two systems agree on, so a member without one
    // cannot be matched to anybody and is not worth a row.
    const members = (result.users ?? []).filter((member) => member.email && member.id);
    if (members.length === 0) return { seen: 0, linked: 0 };

    let linked = 0;
    for (const member of members) {
        const { data, error } = await admin.rpc("import_workspace_member", {
            p_org: orgId,
            p_provider: connection.provider,
            p_external: member.id,
            p_email: member.email,
            p_name: member.name ?? null,
        });
        if (error) {
            // One bad row must not abandon the rest of a company's roster.
            console.warn(`directory import skipped a member of ${connection.provider}: ${error.message}`);
            continue;
        }
        if (data) linked += 1;
    }

    console.info(
        `directory import ${connection.provider}: ${members.length} seen, ${linked} linked into org ${orgId}`,
    );
    return { seen: members.length, linked };
}

/// The organization whose directory a person's connection should populate.
///
/// Administrators only, and this is the whole guard. An administrator
/// connecting the company's Slack is setting the company up; a member
/// connecting their own is linking their own account, and their personal
/// workspace's members have no business becoming the company's colleagues.
export async function directoryTargetOrg(
    admin: SupabaseClient,
    userId: string,
): Promise<string | null> {
    const { data: profile } = await admin
        .from("profiles")
        .select("active_org_id")
        .eq("user_id", userId)
        .maybeSingle<{ active_org_id: string | null }>();

    const orgId = profile?.active_org_id;
    if (!orgId) return null;

    const { data: membership } = await admin
        .from("org_members")
        .select("role")
        .eq("org_id", orgId)
        .eq("user_id", userId)
        .eq("status", "active")
        .maybeSingle<{ role: string }>();

    if (!membership || (membership.role !== "owner" && membership.role !== "admin")) {
        return null;
    }
    return orgId;
}
