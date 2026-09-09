// Whether an organization permits Nod to act in a product at all.
//
// The person's connection is one half of the answer and the company's policy is
// the other, and neither substitutes for the other. This is the second half,
// held in one place because every door that reaches a provider has to ask it and
// three copies of the query would be three chances to ask it differently.
import { adminClient } from "../supabase.ts";
import { ActionError } from "./errors.ts";

/// Refuses unless the organizations this person belongs to permit the provider.
///
/// Throws rather than returning, so a caller cannot reach a provider by
/// forgetting to read a boolean.
///
/// A check that cannot be carried out refuses too, and says so as itself rather
/// than as a policy. Denying with "your organization does not allow this" would
/// state a company's position we failed to read — a lie in the one place a
/// person has no way to verify — and allowing would be the bypass this exists to
/// close. In practice it costs nothing: the same database answers
/// `resolveConnection` a line later, so anything that breaks this breaks the
/// call regardless.
export async function assertProviderPermitted(userId: string, provider: string): Promise<void> {
    const { data, error } = await adminClient().rpc("user_may_use_provider", {
        p_user: userId,
        p_provider: provider,
    });

    if (error) {
        console.error(`integration policy check failed for ${provider}: ${error.message}`);
        throw new ActionError(
            "policy_unavailable",
            `Could not check whether your organization allows ${provider} right now. Try again in a moment.`,
            503,
        );
    }
    if (data === false) {
        throw new ActionError(
            "not_permitted",
            `Your organization does not allow Nod to act in ${provider}.`,
            403,
        );
    }
}

/// The subset of these people whose organizations forbid the provider, for the
/// scheduled sweeps that hold many accounts at once.
///
/// Returns everybody on a failed read, for the opposite reason the door above
/// refuses: a sweep has nobody in front of it to be told anything, and skipping
/// a round of syncing is recoverable where reading a calendar a company
/// forbade is not.
export async function barredUsers(userIds: string[], provider: string): Promise<Set<string>> {
    if (userIds.length === 0) return new Set();

    const { data, error } = await adminClient().rpc("users_barred_from_provider", {
        p_users: userIds,
        p_provider: provider,
    });

    if (error) {
        console.error(`integration policy sweep failed for ${provider}: ${error.message}`);
        return new Set(userIds);
    }
    return new Set(((data ?? []) as { user_id: string }[]).map((row) => row.user_id));
}
