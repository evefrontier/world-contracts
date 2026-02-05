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
    requireEnv,
} from "../utils/helper";
import { keypairFromPrivateKey } from "../utils/client";
import { executeSponsoredTransaction } from "../utils/transaction";

async function jump(
    ctx: ReturnType<typeof initializeContext>,
    character: number,
    sourceGateItemId: bigint,
    destinationGateItemId: bigint,
    playerAddress: string,
    adminAddress: string,
    adminKeypair: ReturnType<typeof keypairFromPrivateKey>
) {
    const { client, keypair: playerKeypair, config } = ctx;

    const characterId = deriveObjectId(config.objectRegistry, character, config.packageId);
    const sourceGateId = deriveObjectId(config.objectRegistry, sourceGateItemId, config.packageId);
    const destinationGateId = deriveObjectId(
        config.objectRegistry,
        destinationGateItemId,
        config.packageId
    );

    const tx = new Transaction();
    tx.setSender(playerAddress);
    tx.setGasOwner(adminAddress);

    tx.moveCall({
        target: `${config.packageId}::${MODULES.GATE}::jump`,
        arguments: [
            tx.object(sourceGateId),
            tx.object(destinationGateId),
            tx.object(characterId),
            tx.object(config.adminAcl),
        ],
    });

    const result = await executeSponsoredTransaction(
        tx,
        client,
        playerKeypair,
        adminKeypair,
        playerAddress,
        adminAddress
    );

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
        const playerKey = requireEnv("PLAYER_A_PRIVATE_KEY");
        const playerCtx = initializeContext(env.network, playerKey);
        await hydrateWorldConfig(playerCtx);
        const adminKeypair = keypairFromPrivateKey(env.adminExportedKey);
        const adminAddress = adminKeypair.getPublicKey().toSuiAddress();
        const playerAddress = playerCtx.address;

        await jump(
            playerCtx,
            GAME_CHARACTER_ID,
            GATE_ITEM_ID_1,
            GATE_ITEM_ID_2,
            playerAddress,
            adminAddress,
            adminKeypair
        );
    } catch (error) {
        handleError(error);
    }
}

main();
