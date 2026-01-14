import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES } from "../utils/config";
import {
    getFuelQuantity,
    getConnectedAssemblies,
    isNetworkNodeOnline,
    getAssemblyTypes,
} from "./helper";
import { deriveObjectId } from "../utils/derive-object-id";
import { CLOCK_OBJECT_ID, NWN_ITEM_ID } from "../utils/constants";
import { initializeContext, handleError, getEnvConfig } from "../utils/helper";

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

    // Determine which assemblies are storage units by querying their types
    const assemblyTypes = await getAssemblyTypes(assemblyIds, client);

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
    for (const { id: assemblyId, isStorageUnit } of assemblyTypes) {
        // Call the appropriate function based on assembly type
        const module = isStorageUnit ? MODULES.STORAGE_UNIT : MODULES.ASSEMBLY;
        const functionName = isStorageUnit
            ? "offline_connected_storage_unit"
            : "offline_connected_assembly";

        const [updatedHotPotato] = tx.moveCall({
            target: `${config.packageId}::${module}::${functionName}`,
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
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.exportedKey);
        const { client, keypair, config } = ctx;

        let networkNodeObject = deriveObjectId(
            config.objectRegistry,
            NWN_ITEM_ID,
            config.packageId
        );

        await updateFuel(networkNodeObject, client, keypair, config);
    } catch (error) {
        handleError(error);
    }
}

main().catch(console.error);
