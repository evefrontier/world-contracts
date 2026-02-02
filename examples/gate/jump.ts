import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { MODULES } from "../utils/config";
import { deriveObjectId } from "../utils/derive-object-id";
import { GAME_CHARACTER_ID, GATE_ITEM_ID_1, GATE_ITEM_ID_2 } from "../utils/constants";
import {
    extractEvent,
    getEnvConfig,
    handleError,
    hydrateWorldConfig,
    initializeContext,
} from "../utils/helper";

async function jump(
    ctx: ReturnType<typeof initializeContext>,
    character: number,
    sourceGateItemId: bigint,
    destinationGateItemId: bigint
) {
    const { client, keypair, config } = ctx;

    const characterId = deriveObjectId(config.objectRegistry, character, config.packageId);
    const sourceGateId = deriveObjectId(config.objectRegistry, sourceGateItemId, config.packageId);
    const destinationGateId = deriveObjectId(
        config.objectRegistry,
        destinationGateItemId,
        config.packageId
    );

    const tx = new Transaction();
    tx.moveCall({
        target: `${config.packageId}::${MODULES.GATE}::jump`,
        arguments: [tx.object(sourceGateId), tx.object(destinationGateId), tx.object(characterId)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEvents: true, showEffects: true, showObjectChanges: true },
    });

    console.log(result);

    const jumpEvent = extractEvent<{
        source_gate_id: string;
        destination_gate_id: string;
        character_id: string;
    }>(result, "::gate::JumpEvent");

    if (jumpEvent) {
        console.log("JumpEvent:", jumpEvent);
    }

    return result;
}

async function main() {
    try {
        const env = getEnvConfig();
        const playerKey = process.env.PLAYER_PRIVATE_KEY;
        const ctx = initializeContext(env.network, playerKey!);
        await hydrateWorldConfig(ctx);
        await jump(ctx, GAME_CHARACTER_ID, GATE_ITEM_ID_1, GATE_ITEM_ID_2);
    } catch (error) {
        handleError(error);
    }
}

main().catch(console.error);
