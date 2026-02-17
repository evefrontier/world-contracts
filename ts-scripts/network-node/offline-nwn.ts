import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES } from "../utils/config";
import { getConnectedAssemblies, getOwnerCap, getAssemblyTypes } from "./helper";
import { deriveObjectId } from "../utils/derive-object-id";
import { CLOCK_OBJECT_ID, GAME_CHARACTER_ID, NWN_ITEM_ID } from "../utils/constants";
import {
    hydrateWorldConfig,
    initializeContext,
    handleError,
    getEnvConfig,
    requireEnv,
} from "../utils/helper";

/**
 * Takes the network node offline and handles connected assemblies.
 *
 * Flow:
 * 1. Query connected assemblies from the network node
 * 2. Determine which assemblies are storage units by querying their types
 * 3. Call offline which returns OfflineAssemblies hot potato
 * 4. Process each assembly:
 *    - Call offline_connected_storage_unit for storage units
 *    - Call offline_connected_assembly for regular assemblies
 *    - Removes from hot potato and brings assembly offline, releases energy
 * 5. Destroy the hot potato (validates list is empty)
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

    const assemblyTypes = await getAssemblyTypes(assemblyIds, client);

    const tx = new Transaction();

    const character = deriveObjectId(config.objectRegistry, GAME_CHARACTER_ID, config.packageId);
    const [ownerCap, receipt] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.NETWORK_NODE}::NetworkNode`],
        arguments: [tx.object(character), tx.object(ownerCapId)],
    });

    // Call offline - returns OfflineAssemblies hot potato
    const [offlineAssemblies] = tx.moveCall({
        target: `${config.packageId}::${MODULES.NETWORK_NODE}::offline`,
        arguments: [
            tx.object(networkNodeId),
            tx.object(config.fuelConfig),
            ownerCap,
            tx.object(CLOCK_OBJECT_ID),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::return_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.NETWORK_NODE}::NetworkNode`],
        arguments: [tx.object(character), ownerCap, receipt],
    });

    // Process each assembly from the hot potato
    // The hot potato contains the assembly IDs connected to the network node
    let currentHotPotato = offlineAssemblies;
    for (const { id: assemblyId, kind } of assemblyTypes) {
        const { module, functionName } =
            kind === "storage_unit"
                ? { module: MODULES.STORAGE_UNIT, functionName: "offline_connected_storage_unit" }
                : kind === "gate"
                  ? { module: MODULES.GATE, functionName: "offline_connected_gate" }
                  : { module: MODULES.ASSEMBLY, functionName: "offline_connected_assembly" };

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

    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    try {
        const env = getEnvConfig();
        const playerKey = requireEnv("PLAYER_A_PRIVATE_KEY");
        const ctx = initializeContext(env.network, playerKey);
        await hydrateWorldConfig(ctx);
        const { client, keypair, config } = ctx;

        const networkNodeObject = deriveObjectId(
            config.objectRegistry,
            NWN_ITEM_ID,
            config.packageId
        );
        const networkNodeOwnerCap = await getOwnerCap(
            networkNodeObject,
            client,
            config,
            ctx.address
        );
        if (!networkNodeOwnerCap) {
            throw new Error(`OwnerCap not found for network node ${networkNodeObject}`);
        }

        await offline(networkNodeObject, networkNodeOwnerCap, client, keypair, config);
    } catch (error) {
        handleError(error);
    }
}

main();
