import { Transaction } from "@mysten/sui/transactions";
import type { Signer } from "@mysten/sui/cryptography";
import type { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import type { WorldConfig } from "../config/types.js";
import { defaultSeeders, type SeederRegistry } from "./seeders.js";
import type { SeedEntry } from "./types.js";

export interface SeedOptions {
    /** Signs and pays for the creation transactions. */
    signer: Signer;
    /** Override the seeder registry (defaults to the SDK's built-in seeders). */
    seeders?: SeederRegistry;
}

export interface SeedResult {
    kind: string;
    id: string;
    status: "created" | "skipped";
}

/**
 * Apply a declarative seed spec to a running world. Additive and idempotent:
 * each entry's object id is derived up front and skipped if it already exists,
 * so re-running a spec — or seeding an existing world — is safe. Entries are
 * processed in order; one shared implementation for CI, the image bake, and
 * downstream builders.
 */
export async function seed(
    client: SuiJsonRpcClient,
    config: WorldConfig,
    spec: readonly SeedEntry[],
    options: SeedOptions
): Promise<SeedResult[]> {
    const seeders = options.seeders ?? defaultSeeders;
    const results: SeedResult[] = [];

    for (const entry of spec) {
        const seeder = seeders[entry.kind];
        if (!seeder) throw new Error(`no seeder registered for kind "${entry.kind}"`);

        const id = seeder.deriveId(config, entry);
        if (await objectExists(client, id)) {
            results.push({ kind: entry.kind, id, status: "skipped" });
            continue;
        }

        const tx = new Transaction();
        seeder.build(tx, config, entry);
        const res = await client.signAndExecuteTransaction({
            signer: options.signer,
            transaction: tx,
            options: { showEffects: true },
        });
        const status = res.effects?.status;
        if (status?.status !== "success") {
            throw new Error(`seed ${entry.kind} ${id} failed: ${status?.error ?? "unknown error"}`);
        }
        results.push({ kind: entry.kind, id, status: "created" });
    }

    return results;
}

async function objectExists(client: SuiJsonRpcClient, id: string): Promise<boolean> {
    const res = await client.getObject({ id });
    return res.data != null;
}
