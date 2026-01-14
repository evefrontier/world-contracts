import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, keypairFromPrivateKey } from "../utils/client";
import { getFuelQuantity, getConnectedAssemblies, isNetworkNodeOnline } from "./helper";
import { deriveObjectId } from "../utils/derive-object-id";
import { CLOCK_OBJECT_ID, NWN_ITEM_ID } from "../utils/constants";

/**
 * Updates fuel for a network node and handles fuel depletion if it occurs.
 *
 * Flow:
 * 1. Query connected assemblies from the network node
 * 2. Call update_fuel which returns OfflineAssemblies hot potato
 *    - Empty hot potato if fuel is still burning or NWN is already offline
 *    - Populated hot potato if fuel gets depleted (NWN changes to offline)
 * 3. Process each assembly:
 *    - Call offline_connected_assembly for each (safely handles empty hot potato)
 *    - If hot potato is populated, brings assembly offline and releases energy
 * 4. Destroy the hot potato (validates list is empty)
 *
 * Note: offline_connected_assembly checks if hot potato is empty internally,
 * so we can safely process all assemblies regardless of hot potato state.
 *
 */
async function updateFuel(
    networkNodeId: string,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Updating Network Node Fuel ====");

    // Get fuel quantity before update
    const fuelBefore = await getFuelQuantity(networkNodeId, client, config);
    console.log(`Fuel quantity before update: ${fuelBefore?.toString()}`);

    const isOnline = await isNetworkNodeOnline(networkNodeId, client, config);
    console.log(`Network node is online: ${isOnline}`);

    // Get connected assemblies before building transaction
    const assemblyIds = (await getConnectedAssemblies(networkNodeId, client, config)) || [];
    console.log(`Found ${assemblyIds.length} connected assemblies`);

    const tx = new Transaction();

    // Step 1: Call update_fuel which returns OfflineAssemblies
    // Returns empty OfflineAssemblies if online, populated if offline (fuel depleted)
    const [offlineAssemblies] = tx.moveCall({
        target: `${config.packageId}::${MODULES.NETWORK_NODE}::update_fuel`,
        arguments: [
            tx.object(networkNodeId),
            tx.object(config.fuelConfig),
            tx.object(config.adminCap),
            tx.object(CLOCK_OBJECT_ID),
        ],
    });

    // Step 2: Process each assembly from the hot potato
    // The hot potato contains the assembly IDs connected to the network node
    let currentHotPotato = offlineAssemblies;
    for (const assemblyId of assemblyIds) {
        // todo: if the assemblyId is of storage unit type then call `offline_connected_assembly` from storage unit module
        // else call assembly module
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

    // Step 3: Destroy the hot potato (validates list is empty)
    tx.moveCall({
        target: `${config.packageId}::${MODULES.NETWORK_NODE}::destroy_offline_assemblies`,
        arguments: [currentHotPotato],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true },
    });

    // Get fuel quantity after update
    const fuelAfter = await getFuelQuantity(networkNodeId, client, config);
    console.log(`Fuel quantity after update: ${fuelAfter?.toString()}`);

    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    try {
        const network = (process.env.SUI_NETWORK as Network) || "localnet";
        const exportedKey = process.env.PRIVATE_KEY;

        if (!exportedKey) {
            throw new Error(
                "PRIVATE_KEY environment variable is required eg: PRIVATE_KEY=suiprivkey1..."
            );
        }

        const client = createClient(network);
        const keypair = keypairFromPrivateKey(exportedKey);
        const config = getConfig(network);

        let networkNodeObject = deriveObjectId(
            config.objectRegistry,
            NWN_ITEM_ID,
            config.packageId
        );

        await updateFuel(networkNodeObject, client, keypair, config);
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
