import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, keypairFromPrivateKey } from "../utils/client";
import { getConnectedAssemblies } from "./helper";

const CLOCK_OBJECT_ID = "0x6";

const NETWORK_NODE_OBJECT_ID = "0x3bda7864385ce8a5b17b7f632d5c5a4137df7ec409dc2a3539174d6d7e686e89";
const OWNER_CAP_OBJECT_ID = "0x9abbaad89ecb2974d37026f511a7366279a1f9b1eb02d61be8856e112132f746";

/**
 * Takes the network node offline and handles connected assemblies.
 *
 * Flow:
 * 1. Query connected assemblies from the network node
 * 2. Call offline which returns OfflineAssemblies hot potato
 * 3. Process each assembly:
 *    - Call offline_connected_assembly for each (removes from hot potato)
 *    - Brings assembly offline and releases energy
 * 4. Destroy the hot potato (validates list is empty)
 */
async function offline(
    networkNodeId: string,
    ownerCapId: string,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Taking Network Node Offline ====");

    // Get connected assembly IDs
    const assemblyIds = (await getConnectedAssemblies(networkNodeId, client, config)) || [];
    console.log(`Found ${assemblyIds.length} connected assemblies`);

    const tx = new Transaction();

    // Call offline - returns OfflineAssemblies hot potato
    const [offlineAssemblies] = tx.moveCall({
        target: `${config.packageId}::${MODULES.NETWORK_NODE}::offline`,
        arguments: [
            tx.object(networkNodeId),
            tx.object(config.fuelConfig),
            tx.object(ownerCapId),
            tx.object(CLOCK_OBJECT_ID),
        ],
    });

    // Process each assembly from the hot potato
    // The hot potato contains the assembly IDs connected to the network node
    let currentHotPotato = offlineAssemblies;
    for (const assemblyId of assemblyIds) {
        const [updatedHotPotato] = tx.moveCall({
            target: `${config.packageId}::${MODULES.ASSEMBLY}::offline_connected_assembly`,
            arguments: [
                tx.object(assemblyId),
                currentHotPotato,
                tx.object(networkNodeId),
                tx.object(config.energyConfig),
            ],
        });
        currentHotPotato = updatedHotPotato;
    }

    // Destroy the hot potato after all assemblies are processed
    // This validates that the list is empty (all assemblies processed)
    if (assemblyIds.length > 0) {
        tx.moveCall({
            target: `${config.packageId}::${MODULES.NETWORK_NODE}::destroy_offline_assemblies`,
            arguments: [currentHotPotato],
        });
    }

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true },
    });

    console.log(result);
    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    console.log("============= Network Node Offline example ==============\n");

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

        console.log("Network:", network);
        console.log("Player address:", playerAddress);

        await offline(NETWORK_NODE_OBJECT_ID, OWNER_CAP_OBJECT_ID, client, keypair, config);
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
