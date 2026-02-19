import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { MODULES } from "../utils/config";
import {
    getEnvConfig,
    handleError,
    hydrateWorldConfig,
    initializeContext,
    parseBigIntArray,
} from "../utils/helper";
import { delay } from "../utils/delay";

async function setGateMaxDistanceByType(
    gateConfigId: string,
    adminAcl: string,
    typeId: bigint,
    maxDistance: bigint,
    ctx: ReturnType<typeof initializeContext>
) {
    const { client, keypair, config } = ctx;

    const tx = new Transaction();
    tx.moveCall({
        target: `${config.packageId}::${MODULES.GATE}::set_max_distance`,
        arguments: [
            tx.object(gateConfigId),
            tx.object(adminAcl),
            tx.pure.u64(typeId),
            tx.pure.u64(maxDistance),
        ],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEffects: true, showObjectChanges: true },
    });

    console.log("\nGate max distance updated!");
    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    console.log("============= Configure Gate Distance example ==============\n");

    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.adminExportedKey);
        const config = await hydrateWorldConfig(ctx);
        const { client } = ctx;

        const adminAcl = config.adminAcl;

        const gateConfigId = config.gateConfig;
        if (!gateConfigId) throw new Error("GateConfig object not found");

        const GATE_TYPE_IDS = parseBigIntArray(process.env.GATE_TYPE_IDS);
        const MAX_DISTANCES = parseBigIntArray(process.env.MAX_DISTANCES);

        // Configure fuel efficiencies
        if (GATE_TYPE_IDS.length > 0 && MAX_DISTANCES.length > 0) {
            if (GATE_TYPE_IDS.length !== MAX_DISTANCES.length) {
                throw new Error(
                    `GATE_TYPE_IDS and MAX_DISTANCES arrays must have the same length. Got ${GATE_TYPE_IDS.length} and ${MAX_DISTANCES.length}`
                );
            }

            for (let i = 0; i < GATE_TYPE_IDS.length; i++) {
                await setGateMaxDistanceByType(
                    gateConfigId,
                    adminAcl,
                    GATE_TYPE_IDS[i],
                    MAX_DISTANCES[i],
                    ctx
                );
                await delay(1000);
            }
        } else {
            console.log("\nNo gate configurations provided. Skipping gate distance setup.");
        }
    } catch (error) {
        handleError(error);
    }
}

main();
