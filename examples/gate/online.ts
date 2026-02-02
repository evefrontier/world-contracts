import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { MODULES } from "../utils/config";
import {
    getEnvConfig,
    handleError,
    hydrateWorldConfig,
    initializeContext,
    requireEnv,
} from "../utils/helper";
import { GAME_CHARACTER_ID, GATE_ITEM_ID_1, GATE_ITEM_ID_2, NWN_ITEM_ID } from "../utils/constants";
import { deriveObjectId } from "../utils/derive-object-id";
import { getOwnerCap } from "./helper";

async function onlineGate(
    ctx: ReturnType<typeof initializeContext>,
    characterId: number,
    nwnId: bigint,
    gateItemId: bigint
) {
    const { client, keypair, config, address } = ctx;

    const characterObjectId = deriveObjectId(config.objectRegistry, characterId, config.packageId);
    const networkNodeObjectId = deriveObjectId(config.objectRegistry, nwnId, config.packageId);
    const gateId = deriveObjectId(config.objectRegistry, gateItemId, config.packageId);

    const gateOwnerCapId = await getOwnerCap(gateId, client, config, address);
    if (!gateOwnerCapId) {
        throw new Error("Gate OwnerCap not found (make sure the character owns the gate)");
    }

    const tx = new Transaction();

    const [gateOwnerCap] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.GATE}::Gate`],
        arguments: [tx.object(characterObjectId), tx.object(gateOwnerCapId)],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.GATE}::online`,
        arguments: [
            tx.object(gateId),
            tx.object(networkNodeObjectId),
            tx.object(config.energyConfig),
            gateOwnerCap,
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::return_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.GATE}::Gate`],
        arguments: [tx.object(characterObjectId), gateOwnerCap],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true, showEvents: true },
    });

    console.log("\nGates brought online successfully!");
    console.log("Transaction digest:", result.digest);
}

async function main() {
    try {
        const env = getEnvConfig();

        const playerKey = requireEnv("PLAYER_A_PRIVATE_KEY");
        const playerCtx = initializeContext(env.network, playerKey);
        await hydrateWorldConfig(playerCtx);

        await onlineGate(playerCtx, GAME_CHARACTER_ID, NWN_ITEM_ID, GATE_ITEM_ID_1);
        await onlineGate(playerCtx, GAME_CHARACTER_ID, NWN_ITEM_ID, GATE_ITEM_ID_2);
    } catch (error) {
        handleError(error);
    }
}

main();
