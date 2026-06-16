import type { SeedEntry } from "./types.js";

/**
 * The default world fixture — the v1 replacement for the old `test-resources.json`
 * shared-inputs file. It holds entity *inputs* (committed), never derived ids:
 * any script applies it, or derives the same ids from it, so independent scripts
 * address the same entities without a generated id file.
 *
 * `owner` is environment-bound (a funded address), so the default binds every
 * character to the seeding signer; supply your own spec for real owners.
 */
export function defaultSeedSpec(owner: string): SeedEntry[] {
    return [
        { kind: "character", inGameId: 1n, tenant: "default", tribeId: 1, owner },
        { kind: "character", inGameId: 2n, tenant: "default", tribeId: 1, owner },
    ];
}
