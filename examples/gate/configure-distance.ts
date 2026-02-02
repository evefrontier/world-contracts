import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { MODULES } from "../utils/config";
import { GATE_TYPE_ID, MAX_DISTANCE } from "../utils/constants";
import {
    getAdminCapId,
    getEnvConfig,
    handleError,
    hydrateWorldConfig,
    initializeContext,
} from "../utils/helper";

async function setGateMaxDistanceByType(
    gateConfigId: string,
    adminCapId: string,
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
            tx.object(adminCapId),
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

        const adminCapId = await getAdminCapId(client, config.packageId);
        if (!adminCapId) throw new Error("AdminCap not found");

        const gateConfigId = config.gateConfig;
        if (!gateConfigId) throw new Error("GateConfig object not found");

        const typeId = GATE_TYPE_ID;
        const maxDistance = MAX_DISTANCE;

        await setGateMaxDistanceByType(gateConfigId, adminCapId, typeId, maxDistance, ctx);
    } catch (error) {
        handleError(error);
    }
}

main();
