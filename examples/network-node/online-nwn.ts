import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { MODULES } from "../utils/config";
import { initializeContext, handleError, getEnvConfig } from "../utils/helper";
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

    const tx = new Transaction();

    const character = deriveObjectId(config.objectRegistry, GAME_CHARACTER_ID, config.packageId);
    tx.moveCall({
        target: `${config.packageId}::${MODULES.NETWORK_NODE}::online`,
        arguments: [
            tx.object(networkNodeId),
            tx.object(character),
            tx.object(ownerCapId),
            tx.object(CLOCK_OBJECT_ID),
        ],
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
        const ctx = initializeContext(env.network, env.playerExportedKey!);
        const playerAddress = ctx.address;

        let networkNodeObject = deriveObjectId(
            ctx.config.objectRegistry,
            NWN_ITEM_ID,
            ctx.config.packageId
        );
        let networkNodeOwnerCap = await getOwnerCap(
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

main().catch(console.error);
