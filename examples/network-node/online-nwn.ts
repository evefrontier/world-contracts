import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, keypairFromPrivateKey } from "../utils/client";
import { CLOCK_OBJECT_ID, NWN_ITEM_ID } from "../utils/constants";
import { deriveObjectId } from "../utils/derive-object-id";
import { getOwnerCap } from "./helper";

async function online(
    networkNodeId: string,
    ownerCapId: string,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Bringing Network Node Online ====");

    const tx = new Transaction();

    tx.moveCall({
        target: `${config.packageId}::${MODULES.NETWORK_NODE}::online`,
        arguments: [tx.object(networkNodeId), tx.object(ownerCapId), tx.object(CLOCK_OBJECT_ID)],
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
        const network = (process.env.SUI_NETWORK as Network) || "localnet";
        const exportedKey = process.env.PLAYER_A_PRIVATE_KEY || process.env.PRIVATE_KEY;

        if (!exportedKey) {
            throw new Error(
                "PLAYER_A_PRIVATE_KEY or PRIVATE_KEY environment variable is required eg: PRIVATE_KEY=suiprivkey1..."
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
        let networkNodeOwnerCap = await getOwnerCap(
            networkNodeObject,
            client,
            config,
            playerAddress
        );
        if (!networkNodeOwnerCap) {
            throw new Error(`OwnerCap not found for network node ${networkNodeObject}`);
        }

        await online(networkNodeObject, networkNodeOwnerCap, client, keypair, config);
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
