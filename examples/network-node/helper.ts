import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient } from "../utils/client";
import { bcs } from "@mysten/sui/bcs";

export async function getFuelQuantity(
    networkNodeId: string,
    client: SuiClient,
    config: ReturnType<typeof getConfig>,
    senderAddress?: string
): Promise<bigint | null> {
    try {
        const tx = new Transaction();

        // Simulate the transaction (read-only, doesn't execute on-chain)
        tx.moveCall({
            target: `${config.packageId}::${MODULES.NETWORK_NODE}::fuel_quantity`,
            arguments: [tx.object(networkNodeId)],
        });

        const result = await client.devInspectTransactionBlock({
            sender: senderAddress || process.env.ADMIN_ADDRESS || "0x",
            transactionBlock: tx,
        });

        if (result.effects?.status?.status !== "success") {
            console.warn("Error getting fuel quantity:", result.effects?.status?.error);
            return null;
        }

        const returnValues = result.results?.[0]?.returnValues;
        if (returnValues && returnValues.length > 0) {
            const [valueBytes] = returnValues[0];
            // Decode the u64 value
            const fuelQuantity = bcs.u64().parse(Uint8Array.from(valueBytes));
            return BigInt(fuelQuantity);
        }

        return null;
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
    client: SuiClient,
    config: ReturnType<typeof getConfig>,
    senderAddress?: string
): Promise<string[] | null> {
    try {
        const tx = new Transaction();

        // Simulate the transaction (read-only, doesn't execute on-chain)
        tx.moveCall({
            target: `${config.packageId}::${MODULES.NETWORK_NODE}::connected_assemblies`,
            arguments: [tx.object(networkNodeId)],
        });

        const result = await client.devInspectTransactionBlock({
            sender: senderAddress || process.env.ADMIN_ADDRESS || "0x",
            transactionBlock: tx,
        });

        if (result.effects?.status?.status !== "success") {
            console.warn("Error getting connected assemblies:", result.effects?.status?.error);
            return null;
        }

        const returnValues = result.results?.[0]?.returnValues;
        if (returnValues && returnValues.length > 0) {
            const [valueBytes] = returnValues[0];
            // Decode the vector<ID> value - ID is encoded as address in BCS
            const assemblyIds = bcs.vector(bcs.Address).parse(Uint8Array.from(valueBytes));
            return assemblyIds.map((addr) => addr);
        }

        return null;
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
    client: SuiClient,
    config: ReturnType<typeof getConfig>,
    senderAddress?: string
): Promise<boolean | null> {
    try {
        const tx = new Transaction();

        tx.moveCall({
            target: `${config.packageId}::${MODULES.NETWORK_NODE}::is_network_node_online`,
            arguments: [tx.object(networkNodeId)],
        });

        const result = await client.devInspectTransactionBlock({
            sender: senderAddress || process.env.ADMIN_ADDRESS || "0x",
            transactionBlock: tx,
        });

        if (result.effects?.status?.status !== "success") {
            console.warn("Error checking network node status:", result.effects?.status?.error);
            return null;
        }

        const returnValues = result.results?.[0]?.returnValues;
        if (returnValues && returnValues.length > 0) {
            const [valueBytes] = returnValues[0];
            const isOnline = bcs.bool().parse(Uint8Array.from(valueBytes));
            return isOnline;
        }

        return null;
    } catch (error) {
        console.warn(
            "Failed to check network node status:",
            error instanceof Error ? error.message : error
        );
        return null;
    }
}
