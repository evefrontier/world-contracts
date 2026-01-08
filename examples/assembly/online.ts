import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, keypairFromPrivateKey } from "../utils/client";

const NETWORK_NODE_OBJECT_ID = "0x24e93560b47cd5e8fa8ea532859bc415fa7426f9b5267c8623dacec67d56e175";
const ASSEMBLY_ID = "0xd1d7ce069b1c849501676a6c79c4329eb0d21be85a2ee896f54407614538c5b0";
const OWNER_CAP_ID = "0x051e0614313016476fe6fe32f81904026d9952e6f1e27edcd30c3467037d64e3";

export async function online(
    assemblyId: string,
    ownerCapId: string,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Bringing Assembly Online ====");
    const tx = new Transaction();

    tx.moveCall({
        target: `${config.packageId}::${MODULES.ASSEMBLY}::online`,
        arguments: [
            tx.object(assemblyId),
            tx.object(NETWORK_NODE_OBJECT_ID),
            tx.object(config.energyConfig),
            tx.object(ownerCapId),
        ],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true },
    });

    console.log("\n Assembly brought online successfully!");
    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    console.log("============= online assembly example ==============\n");

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

        console.log("Network:", network);
        console.log("Player address:", playerAddress);

        await online(ASSEMBLY_ID, OWNER_CAP_ID, client, keypair, config);
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
