import "dotenv/config";
import { bcs } from "@mysten/sui/bcs";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, keypairFromPrivateKey } from "../utils/client";
import { deriveObjectId } from "../utils/derive-object-id";
import { NWN_ITEM_ID, STORAGE_A_ITEM_ID } from "../utils/constants";
import { getOwnerCap } from "./helper";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

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
        const network = (process.env.SUI_NETWORK as Network) || "localnet";
        const exportedKey = process.env.PLAYER_A_PRIVATE_KEY || process.env.PRIVATE_KEY;

        if (!exportedKey) {
            throw new Error(
                "PLAYER_A_PRIVATE_KEY environment variable is required eg: PRIVATE_KEY=suiprivkey1..."
            );
        }

        const client = createClient(network);
        const keypair = keypairFromPrivateKey(exportedKey);
        const config = getConfig(network);
        const playerAddress = keypair.getPublicKey().toSuiAddress();

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

        let assemblyOwnerCap = await getOwnerCap(assemblyObject, client, config, playerAddress);
        if (!assemblyOwnerCap) {
            throw new Error(`OwnerCap not found for ${assemblyObject}`);
        }

        await online(networkNodeObject, assemblyObject, assemblyOwnerCap, client, keypair, config);
    } catch (error) {
        console.error("\n=== Error ===");
        console.error("Error:", error instanceof Error ? error.message : error);
        if (error instanceof Error && error.stack) {
            console.error("Stack:", error.stack);
        }
        process.exit(1);
    }
}

main().catch(console.error);
