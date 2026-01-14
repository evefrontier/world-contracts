import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, keypairFromPrivateKey } from "../utils/client";
import { getConnectedAssemblies, getOwnerCap } from "./helper";
import { deriveObjectId } from "../utils/derive-object-id";
import { CLOCK_OBJECT_ID, NWN_ITEM_ID } from "../utils/constants";

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

        await offline(networkNodeObject, networkNodeOwnerCap, client, keypair, config);
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
