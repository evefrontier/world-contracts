import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES } from "../utils/config";
import { getConnectedAssemblies, getAssemblyTypes } from "./helper";
import { deriveObjectId } from "../utils/derive-object-id";
import { NWN_ITEM_ID } from "../utils/constants";
import {
    hydrateWorldConfig,
    initializeContext,
    handleError,
    getEnvConfig,
    getAdminCapId,
} from "../utils/helper";

/**
 * Unanchors (destroys) the network node and handles connected assemblies.
 *
 * Flow:
 * 1. Query connected assemblies from the network node
 * 2. Determine which assemblies are storage units by querying their types
 * 3. Call unanchor which returns HandleOrphanedAssemblies hot potato
 * 4. Process each assembly:
 *    - Call unanchor_connected_storage_unit or offline_orphaned_assembly
 *    - Brings assembly offline, releases energy, and clears its energy source (assembly can later be attached to another NWN)
 * 5. Call destroy_network_node to consume the hot potato and destroy the NWN
 */
async function unanchor(
    networkNodeId: string,
    adminCapId: string,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Unanchoring (Destroying) Network Node ====");

    const assemblyIds = (await getConnectedAssemblies(networkNodeId, client, config)) || [];
    console.log(`Found ${assemblyIds.length} connected assemblies`);

    const assemblyTypes = await getAssemblyTypes(assemblyIds, client);

    const tx = new Transaction();

    // Call unanchor - returns HandleOrphanedAssemblies hot potato (NWN is still alive until destroy_network_node)
    const [unanchorAssemblies] = tx.moveCall({
        target: `${config.packageId}::${MODULES.NETWORK_NODE}::unanchor`,
        arguments: [tx.object(networkNodeId), tx.object(adminCapId)],
    });

    let currentHotPotato = unanchorAssemblies;
    for (const { id: assemblyId, kind } of assemblyTypes) {
        const { module, functionName } =
            kind === "storage_unit"
                ? { module: MODULES.STORAGE_UNIT, functionName: "offline_orphaned_storage_unit" }
                : kind === "gate"
                  ? { module: MODULES.GATE, functionName: "offline_orphaned_gate" }
                  : { module: MODULES.ASSEMBLY, functionName: "offline_orphaned_assembly" };

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

    // Destroy the network node (consumes hot potato and NWN)
    tx.moveCall({
        target: `${config.packageId}::${MODULES.NETWORK_NODE}::destroy_network_node`,
        arguments: [tx.object(networkNodeId), currentHotPotato, tx.object(adminCapId)],
    });

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
        const ctx = initializeContext(env.network, env.adminExportedKey);
        await hydrateWorldConfig(ctx);
        const { client, keypair, config } = ctx;

        const adminCapId = await getAdminCapId(client, config.packageId);
        if (!adminCapId) throw new Error("AdminCap not found");

        const networkNodeObject = deriveObjectId(
            config.objectRegistry,
            NWN_ITEM_ID,
            config.packageId
        );

        await unanchor(networkNodeObject, adminCapId!, client, keypair, config);
    } catch (error) {
        handleError(error);
    }
}

main();
