import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { MODULES } from "../utils/config";
import {
    hydrateWorldConfig,
    initializeContext,
    handleError,
    getEnvConfig,
    requireEnv,
} from "../utils/helper";
import { CLOCK_OBJECT_ID, GAME_CHARACTER_ID, NWN_ITEM_ID } from "../utils/constants";
import { deriveObjectId } from "../utils/derive-object-id";
import { getOwnerCap } from "./helper";

async function online(
    networkNodeId: string,
    ownerCapId: string,
    ctx: ReturnType<typeof initializeContext>
) {
    const { client, keypair, config } = ctx;
    console.log("\n==== Bringing Network Node Online ====");

    const characterId = deriveObjectId(config.objectRegistry, GAME_CHARACTER_ID, config.packageId);

    const tx = new Transaction();

    // 1. Borrow OwnerCap from character (Receiving ticket = object ref of OwnerCap owned by character)
    const [ownerCap, receipt] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.NETWORK_NODE}::NetworkNode`],
        arguments: [tx.object(characterId), tx.object(ownerCapId)],
    });

    // 2. Use the borrowed OwnerCap to bring the network node online
    tx.moveCall({
        target: `${config.packageId}::${MODULES.NETWORK_NODE}::online`,
        arguments: [tx.object(networkNodeId), ownerCap, tx.object(CLOCK_OBJECT_ID)],
    });

    // 3. Return the OwnerCap to the character
    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::return_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.NETWORK_NODE}::NetworkNode`],
        arguments: [tx.object(characterId), ownerCap, receipt],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true },
    });

    console.log("\n Network Node brought online successfully!");
    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    try {
        const env = getEnvConfig();
        const playerKey = requireEnv("PLAYER_A_PRIVATE_KEY");
        const ctx = initializeContext(env.network, playerKey);
        await hydrateWorldConfig(ctx);
        const playerAddress = ctx.address;

        const networkNodeObject = deriveObjectId(
            ctx.config.objectRegistry,
            NWN_ITEM_ID,
            ctx.config.packageId
        );
        const networkNodeOwnerCap = await getOwnerCap(
            networkNodeObject,
            ctx.client,
            ctx.config,
            playerAddress
        );
        if (!networkNodeOwnerCap) {
            throw new Error(`OwnerCap not found for network node ${networkNodeObject}`);
        }

        await online(networkNodeObject, networkNodeOwnerCap, ctx);
    } catch (error) {
        handleError(error);
    }
}

main();
