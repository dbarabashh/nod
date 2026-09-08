/// The reference a checklist row already carries, when it does.
///
/// A proposal and the row's own filing mark are two doors to the same ticket.
/// The client hides one once the other has been used, but the client is the
/// same program that raised the proposal; this is the server's own check, so a
/// row filed by hand a minute ago is never filed again by the offer that was
/// still on screen.
export interface FiledRow {
    external_provider: string | null;
    external_key: string | null;
    external_url: string | null;
    deleted_at?: string | null;
}

export function filedReference(row: FiledRow | null | undefined): { key: string; url: string; provider: string } | null {
    if (!row?.external_provider || !row.external_key || !row.external_url) return null;
    return { provider: row.external_provider, key: row.external_key, url: row.external_url };
}
