import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { loadWorldConfig } from "../config/load.js";
import { createWorldClient } from "../client.js";
import { seed } from "../seed/seed.js";
import type { SeedEntry } from "../seed/types.js";

// Integration: applies a seed spec against a running localnet and checks idempotency.
// Unlike the createCharacter test (read-only devInspect), seeding executes, so it needs
// a funded key. Requires deployments/localnet/world.json + a running chain. Skips without
// SUI_PRIVATE_KEY. Run with: pnpm --filter @evefrontier/world-sdk test:integration
const MANIFEST = fileURLToPath(
    new URL("../../../../deployments/localnet/world.json", import.meta.url)
);
const privateKey = process.env.SUI_PRIVATE_KEY;
const maybe = privateKey ? describe : describe.skip;

maybe("seed (localnet)", () => {
    const keypair = Ed25519Keypair.fromSecretKey(privateKey!);
    const config = loadWorldConfig(MANIFEST);
    const client = createWorldClient({ config });
    // Distinct tenant so the run is self-contained regardless of prior state.
    const spec: SeedEntry[] = [
        { kind: "character", inGameId: 101n, tenant: "seed-it", tribeId: 1, owner: keypair.toSuiAddress() },
    ];

    it("creates on first apply and skips on re-apply (idempotent)", async () => {
        const first = await seed(client, config, spec, { signer: keypair });
        expect(first.every((r) => r.status === "created" || r.status === "skipped")).toBe(true);

        const second = await seed(client, config, spec, { signer: keypair });
        expect(second.map((r) => r.status)).toEqual(spec.map(() => "skipped"));
        // Same derived id across runs — the spec, not a generated id file, is the source.
        expect(second.map((r) => r.id)).toEqual(first.map((r) => r.id));
    });
});
