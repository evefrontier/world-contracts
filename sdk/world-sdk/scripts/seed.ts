import { fileURLToPath } from "node:url";
import "dotenv/config";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { loadWorldConfig } from "../src/config/load.js";
import { createWorldClient } from "../src/client.js";
import { seed } from "../src/seed/seed.js";
import { defaultSeedSpec } from "../src/seed/spec.js";

// Apply the default seed spec to a running localnet. Idempotent: re-running skips
// entities that already exist. Replaces the old scripts/seed-world.sh stub.
const MANIFEST = fileURLToPath(
    new URL("../../../deployments/localnet/world.json", import.meta.url)
);

const privateKey = process.env.SUI_PRIVATE_KEY;
if (!privateKey) {
    throw new Error("SUI_PRIVATE_KEY is required (a funded localnet key, suiprivkey1...)");
}
const keypair = Ed25519Keypair.fromSecretKey(privateKey);

const config = loadWorldConfig(MANIFEST);
const client = createWorldClient({ config });

const results = await seed(client, config, defaultSeedSpec(keypair.toSuiAddress()), {
    signer: keypair,
});

for (const r of results) {
    console.log(`${r.status.padEnd(7)} ${r.kind} ${r.id}`);
}
