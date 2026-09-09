export type ContactTopicSubscription = "opt_in" | "opt_out";

export interface ContactSyncResult {
    error: string | null;
    retryable: boolean;
}

// Mirrors one topic decision onto the provider. Opting out never creates a
// contact: if Resend has never heard of this address, "unsubscribed" is already
// the truth and we leave it that way.
export async function syncContactTopic(
    request: (path: string, init: RequestInit) => Promise<Response>,
    email: string,
    topicId: string,
    subscription: ContactTopicSubscription,
): Promise<ContactSyncResult> {
    const topics = [{ id: topicId, subscription }];

    if (subscription === "opt_out") {
        const updated = await request(`/contacts/${encodeURIComponent(email)}/topics`, {
            method: "PATCH",
            body: JSON.stringify(topics),
        });
        if (updated.ok || updated.status === 404) return { error: null, retryable: false };
        return contactFailure("update opted-out contact topic", updated);
    }

    const created = await request("/contacts", {
        method: "POST",
        body: JSON.stringify({ email, topics }),
    });
    if (created.ok) return { error: null, retryable: false };
    // 409 means the contact exists already, which is the normal case for a
    // second topic.
    if (created.status !== 409) return contactFailure("create opted-in contact", created);

    const updated = await request(`/contacts/${encodeURIComponent(email)}/topics`, {
        method: "PATCH",
        body: JSON.stringify(topics),
    });
    if (updated.ok) return { error: null, retryable: false };
    return contactFailure("update opted-in contact topic", updated);
}

async function contactFailure(operation: string, response: Response): Promise<ContactSyncResult> {
    const body = (await response.text()).slice(0, 300);
    return {
        error: `${operation} status=${response.status} body=${body}`,
        retryable: response.status === 429 || response.status >= 500,
    };
}
