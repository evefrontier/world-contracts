import { describe, expect, it } from "vitest";
import { Transaction } from "@mysten/sui/transactions";
import { loadWorldConfig } from "../config/load.js";
import { deriveObjectId } from "../packages/core.js";
import { createWorldClient } from "../client.js";
import { createCharacter } from "../packages/character.js";

// Integration: exercises the createCharacter binding against a running localnet.
// Requires `pnpm deploy:localnet` (or equivalent) so deployments/localnet/world.json
// exists and the chain is up. Run with: pnpm --filter @evefrontier/world-sdk test:integration
const MANIFEST = new URL("../../../../deployments/localnet/world.json", import.meta.url).pathname;
// devInspect is a read-only simulation, so any valid address works as the sender.
const SENDER =
    process.env.SENDER ?? "0x0000000000000000000000000000000000000000000000000000000000000001";

describe("createCharacter (localnet)", () => {
    const config = loadWorldConfig(MANIFEST, "local");
    const client = createWorldClient({ config });

    it("builds a character::create call the chain accepts, at the derived id", async () => {
        const key = { id: 7n, tenant: "integration" };
        const tx = new Transaction();
        createCharacter(tx, config, {
            inGameId: key.id,
            tenant: key.tenant,
            tribeId: 1,
            owner: SENDER,
        });

        const res = await client.devInspectTransactionBlock({
            sender: SENDER,
            transactionBlock: tx,
        });

        expect(res.effects?.status?.status, res.effects?.status?.error ?? "").toBe("success");

        const created = (res.effects?.created ?? []).map((c) => c.reference.objectId);
        expect(created).toContain(deriveObjectId(config, key));
    });
});
