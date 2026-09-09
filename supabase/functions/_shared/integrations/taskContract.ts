// What every tracker answers to.
//
// A task action is a verb, and the product is the default it runs in: the
// desktop files, searches, reads back and updates with one set of shapes and
// swaps only the provider name. The names here are the ones the client's
// `IntegrationProvider.taskActions` carries, and `taskContract.test.ts` holds
// every adapter to them, so a tracker that stops answering one is caught before
// a checkbox finds out.

export interface TaskProvider {
    provider: string;
    create: string;
    search: string;
    readStatus: string;
    update: string;
}

const ISSUE_ACTIONS = {
    create: "create_issue",
    search: "search_issues",
    readStatus: "read_issues",
    update: "update_issue",
};

const TASK_ACTIONS = {
    create: "create_task",
    search: "search_tasks",
    readStatus: "read_tasks",
    update: "update_task",
};

export const TASK_PROVIDERS: readonly TaskProvider[] = [
    { provider: "linear", ...ISSUE_ACTIONS },
    { provider: "jira", ...ISSUE_ACTIONS },
    { provider: "asana", ...TASK_ACTIONS },
    { provider: "google-tasks", ...TASK_ACTIONS },
];

export interface TaskReference {
    key: string;
    title: string;
    url?: string;
    closed: boolean;
}

export interface TaskFields {
    key: string;
    title?: string | null;
    url?: string | null;
    closed?: boolean | null;
}

/// The four words a task action answers with, whichever product answered.
///
/// `url` is left out rather than sent empty: a client turns it into a link,
/// and no link is better than one to nowhere. Anything else the adapter adds
/// — a state name, an assignee — rides along untouched for the model.
export function taskReference(fields: TaskFields & Record<string, unknown>): TaskReference & Record<string, unknown> {
    const { key, title, url, closed, ...extra } = fields;
    return {
        ...extra,
        key,
        title: title ?? "",
        ...(url ? { url } : {}),
        closed: closed === true,
    };
}
