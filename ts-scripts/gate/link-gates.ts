import "dotenv/config";
import { bcs } from "@mysten/sui/bcs";
import { Transaction } from "@mysten/sui/transactions";
import { MODULES } from "../utils/config";
import { deriveObjectId } from "../utils/derive-object-id";
import {
    CLOCK_OBJECT_ID,
    GAME_CHARACTER_ID,
    GATE_ITEM_ID_1,
    GATE_ITEM_ID_2,
    PLAYER_A_PROOF,
} from "../utils/constants";
import {
    getEnvConfig,
    handleError,
    hexToBytes,
    hydrateWorldConfig,
    initializeContext,
    requireEnv,
} from "../utils/helper";
import { getOwnerCap } from "./helper";

async function linkGates(
    ctx: ReturnType<typeof initializeContext>,
    character: number,
    gateAItemId: bigint,
    gateBItemId: bigint
) {
    const { client, keypair, config, address } = ctx;

    const characterId = deriveObjectId(config.objectRegistry, character, config.packageId);
    const gateAId = deriveObjectId(config.objectRegistry, gateAItemId, config.packageId);
    const gateBId = deriveObjectId(config.objectRegistry, gateBItemId, config.packageId);

    const gateConfigId = config.gateConfig;

    const gateAOwnerCapId = await getOwnerCap(gateAId, client, config, address);
    const gateBOwnerCapId = await getOwnerCap(gateBId, client, config, address);
    if (!gateAOwnerCapId || !gateBOwnerCapId) {
        throw new Error("Gate OwnerCaps not found (make sure the character owns both gates)");
    }

    const tx = new Transaction();

    const [gateAOwnerCap] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.GATE}::Gate`],
        arguments: [tx.object(characterId), tx.object(gateAOwnerCapId)],
    });

    const [gateBOwnerCap] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.GATE}::Gate`],
        arguments: [tx.object(characterId), tx.object(gateBOwnerCapId)],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.GATE}::link_gates`,
        arguments: [
            tx.object(gateAId),
            tx.object(gateBId),
            tx.object(characterId),
            tx.object(gateConfigId),
            tx.object(config.serverAddressRegistry),
            gateAOwnerCap,
            gateBOwnerCap,
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(PLAYER_A_PROOF))),
            tx.object(CLOCK_OBJECT_ID),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::return_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.GATE}::Gate`],
        arguments: [tx.object(characterId), gateAOwnerCap],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::return_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.GATE}::Gate`],
        arguments: [tx.object(characterId), gateBOwnerCap],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEffects: true, showObjectChanges: true, showEvents: true },
    });

    console.log("\nGates linked successfully!");
    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    try {
        const env = getEnvConfig();
        const playerKey = requireEnv("PLAYER_A_PRIVATE_KEY");
        const ctx = initializeContext(env.network, playerKey);
        await hydrateWorldConfig(ctx);
        await linkGates(ctx, GAME_CHARACTER_ID, GATE_ITEM_ID_1, GATE_ITEM_ID_2);
    } catch (error) {
        handleError(error);
    }
}

main();
