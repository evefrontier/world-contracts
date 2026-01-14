import "dotenv/config";
import { bcs } from "@mysten/sui/bcs";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES } from "../utils/config";
import { deriveObjectId } from "../utils/derive-object-id";
import { NWN_ITEM_ID, STORAGE_A_ITEM_ID } from "../utils/constants";
import { initializeContext, handleError, getEnvConfig } from "../utils/helper";
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
    const tx = new Transaction();

    tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::online`,
        arguments: [
            tx.object(assemblyId),
            tx.object(networkObjectId),
            tx.object(config.energyConfig),
            tx.object(ownerCapId),
        ],
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
        const playerCtx = initializeContext(env.network, env.playerExportedKey!);
        const { client, keypair, config } = playerCtx;

        let networkNodeObject = deriveObjectId(
            config.objectRegistry,
            NWN_ITEM_ID,
            config.packageId
        );

        let assemblyObject = deriveObjectId(
            config.objectRegistry,
            STORAGE_A_ITEM_ID,
            config.packageId
        );

        let assemblyOwnerCap = await getOwnerCap(assemblyObject, client, config, playerCtx.address);
        if (!assemblyOwnerCap) {
            throw new Error(`OwnerCap not found for ${assemblyObject}`);
        }

        await online(networkNodeObject, assemblyObject, assemblyOwnerCap, client, keypair, config);
    } catch (error) {
        handleError(error);
    }
}

main().catch(console.error);
