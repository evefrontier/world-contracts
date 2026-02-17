import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES } from "../utils/config";
import { deriveObjectId } from "../utils/derive-object-id";
import { GAME_CHARACTER_ID, NWN_ITEM_ID, STORAGE_A_ITEM_ID } from "../utils/constants";
import {
    hydrateWorldConfig,
    initializeContext,
    handleError,
    getEnvConfig,
    requireEnv,
} from "../utils/helper";
import { getOwnerCap } from "./helper";

export async function online(
    networkObjectId: string,
    assemblyId: string,
    ownerCapId: string,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Bringing Storage Unit Online ====");
    const characterId = deriveObjectId(config.objectRegistry, GAME_CHARACTER_ID, config.packageId);
    const tx = new Transaction();

    const [ownerCap, receipt] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.STORAGE_UNIT}::StorageUnit`],
        arguments: [tx.object(characterId), tx.object(ownerCapId)],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::online`,
        arguments: [
            tx.object(assemblyId),
            tx.object(networkObjectId),
            tx.object(config.energyConfig),
            ownerCap,
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::return_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.STORAGE_UNIT}::StorageUnit`],
        arguments: [tx.object(characterId), ownerCap, receipt],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true },
    });

    console.log("\n Storage Unit brought online successfully!");
    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    try {
        const env = getEnvConfig();
        const playerKey = requireEnv("PLAYER_A_PRIVATE_KEY");
        const playerCtx = initializeContext(env.network, playerKey);
        await hydrateWorldConfig(playerCtx);
        const { client, keypair, config } = playerCtx;

        const networkNodeObject = deriveObjectId(
            config.objectRegistry,
            NWN_ITEM_ID,
            config.packageId
        );

        const assemblyObject = deriveObjectId(
            config.objectRegistry,
            STORAGE_A_ITEM_ID,
            config.packageId
        );

        const assemblyOwnerCap = await getOwnerCap(
            assemblyObject,
            client,
            config,
            playerCtx.address
        );
        if (!assemblyOwnerCap) {
            throw new Error(`OwnerCap not found for ${assemblyObject}`);
        }

        await online(networkNodeObject, assemblyObject, assemblyOwnerCap, client, keypair, config);
    } catch (error) {
        handleError(error);
    }
}

main();
