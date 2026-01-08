import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, keypairFromPrivateKey } from "../utils/client";

const CLOCK_OBJECT_ID = "0x6";

const NETWORK_NODE_OBJECT_ID = "0x24e93560b47cd5e8fa8ea532859bc415fa7426f9b5267c8623dacec67d56e175";
const OWNER_CAP_OBJECT_ID = "0x62deeaf9f6fce5e2b115aa054e6f0a7087cc0bf641dd4a61545ce087e1c1ffab";

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
    console.log("============= Network Node Online example ==============\n");

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

        await online(NETWORK_NODE_OBJECT_ID, OWNER_CAP_OBJECT_ID, client, keypair, config);
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
