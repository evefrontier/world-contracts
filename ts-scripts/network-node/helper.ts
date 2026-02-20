import "dotenv/config";
import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { getConfig, MODULES } from "../utils/config";
import { bcs } from "@mysten/sui/bcs";
import { devInspectMoveCallFirstReturnValueBytes } from "../utils/dev-inspect";

export interface AssemblyTypeInfo {
    id: string;
    kind: "assembly" | "storage_unit" | "gate";
}

export async function getFuelQuantity(
    networkNodeId: string,
    client: SuiJsonRpcClient,
    config: ReturnType<typeof getConfig>,
    senderAddress?: string
): Promise<bigint | null> {
    try {
        const bytes = await devInspectMoveCallFirstReturnValueBytes(client, {
            target: `${config.packageId}::${MODULES.NETWORK_NODE}::fuel_quantity`,
            senderAddress,
            arguments: (tx) => [tx.object(networkNodeId)],
        });

        if (!bytes) {
            console.warn("Error getting fuel quantity");
            return null;
        }

        const fuelQuantity = bcs.u64().parse(bytes);
        return BigInt(fuelQuantity);
    } catch (error) {
        console.warn(
            "Failed to get fuel quantity:",
            error instanceof Error ? error.message : error
        );
        return null;
    }
}

export async function getConnectedAssemblies(
    networkNodeId: string,
    client: SuiJsonRpcClient,
    config: ReturnType<typeof getConfig>,
    senderAddress?: string
): Promise<string[] | null> {
    try {
        const bytes = await devInspectMoveCallFirstReturnValueBytes(client, {
            target: `${config.packageId}::${MODULES.NETWORK_NODE}::connected_assemblies`,
            senderAddress,
            arguments: (tx) => [tx.object(networkNodeId)],
        });

        if (!bytes) {
            console.warn("Error getting connected assemblies");
            return null;
        }

        const assemblyIds = bcs.vector(bcs.Address).parse(bytes);
        return assemblyIds.map((addr) => addr);
    } catch (error) {
        console.warn(
            "Failed to get connected assemblies:",
            error instanceof Error ? error.message : error
        );
        return null;
    }
}

export async function isNetworkNodeOnline(
    networkNodeId: string,
    client: SuiJsonRpcClient,
    config: ReturnType<typeof getConfig>,
    senderAddress?: string
): Promise<boolean | null> {
    try {
        const bytes = await devInspectMoveCallFirstReturnValueBytes(client, {
            target: `${config.packageId}::${MODULES.NETWORK_NODE}::is_network_node_online`,
            senderAddress,
            arguments: (tx) => [tx.object(networkNodeId)],
        });

        if (!bytes) {
            console.warn("Error checking network node status");
            return null;
        }

        return bcs.bool().parse(bytes);
    } catch (error) {
        console.warn(
            "Failed to check network node status:",
            error instanceof Error ? error.message : error
        );
        return null;
    }
}

export async function getOwnerCap(
    networkNodeId: string,
    client: SuiJsonRpcClient,
    config: ReturnType<typeof getConfig>,
    senderAddress?: string
): Promise<string | null> {
    try {
        const bytes = await devInspectMoveCallFirstReturnValueBytes(client, {
            target: `${config.packageId}::${MODULES.NETWORK_NODE}::owner_cap_id`,
            senderAddress,
            arguments: (tx) => [tx.object(networkNodeId)],
        });

        if (!bytes) {
            console.warn("Error checking ownercap id");
            return null;
        }
        return bcs.Address.parse(bytes);
    } catch (error) {
        console.warn("Failed to get ownerCap:", error instanceof Error ? error.message : error);
        return null;
    }
}

export async function getAssemblyTypes(
    assemblyIds: string[],
    client: SuiJsonRpcClient
): Promise<AssemblyTypeInfo[]> {
    return await Promise.all(
        assemblyIds.map(async (assemblyId) => {
            try {
                const object = await client.getObject({
                    id: assemblyId,
                    options: { showType: true },
                });
                const type = object.data?.type;

                // connected_assembly_ids can include multiple "assembly-like" structs,
                // including `Gate` and `StorageUnit`, which require different Move entrypoints.
                if (type?.includes(`::${MODULES.GATE}::Gate`)) {
                    return { id: assemblyId, kind: "gate" };
                }

                if (type?.includes("StorageUnit")) {
                    return { id: assemblyId, kind: "storage_unit" };
                }

                return { id: assemblyId, kind: "assembly" };
            } catch (error) {
                console.warn(`Failed to get type for assembly ${assemblyId}:`, error);
                // Default to assembly module if we can't determine the type
                return { id: assemblyId, kind: "assembly" };
            }
        })
    );
}
