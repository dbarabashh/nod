/// One account the broker holds for a person, or one row we hold for them.
export interface Live {
  provider: string;
  accountId: string;
}

/// What changed between what we hold and what the broker reports.
///
/// Keyed on the account, not on the provider name. Named alone, a provider
/// already in the table looks unchanged however much has happened to it — so a
/// grant that died at the provider and was authorized again, minting a fresh
/// account, produced no `arrived` entry, the upsert below never ran, and the
/// row kept pointing at an account nobody can reach. The person sees
/// "Connected" and every call fails, with reconnecting unable to fix it because
/// reconnecting is exactly what does not register.
///
/// Its own module so it can be tested without a broker or a database: the
/// whole behaviour is in these four lines, and the failure it prevents is
/// invisible from the outside.
export function diff(stored: Live[], live: Live[]): { arrived: Live[]; departed: string[]; nowLive: string[] } {
  const heldAccount = new Map(stored.map((entry) => [entry.provider, entry.accountId]));
  const nowLive = live.map((entry) => entry.provider);
  return {
    arrived: live.filter((entry) => heldAccount.get(entry.provider) !== entry.accountId),
    departed: [...heldAccount.keys()].filter((provider) => !nowLive.includes(provider)),
    nowLive,
  };
}
