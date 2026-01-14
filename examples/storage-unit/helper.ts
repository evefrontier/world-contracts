import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { getConfig, MODULES } from "../utils/config";
import { bcs } from "@mysten/sui/bcs";

export async function getOwnerCap(
    assemblyId: string,
    client: SuiClient,
    config: ReturnType<typeof getConfig>,
    senderAddress?: string
): Promise<string | null> {
    try {
        const tx = new Transaction();

        tx.moveCall({
            target: `${config.packageId}::${MODULES.STORAGE_UNIT}::owner_cap_id`,
            arguments: [tx.object(assemblyId)],
        });

        const result = await client.devInspectTransactionBlock({
            sender: senderAddress || process.env.ADMIN_ADDRESS || "0x",
            transactionBlock: tx,
        });

        if (result.effects?.status?.status !== "success") {
            console.warn("Error checking ownercap id:", result.effects?.status?.error);
            return null;
        }
        const returnValues = result.results?.[0]?.returnValues;

        if (returnValues && returnValues.length > 0) {
            const [valueBytes] = returnValues[0];
            const ownerCapId = bcs.Address.parse(Uint8Array.from(valueBytes));
            return ownerCapId;
        }

        return null;
    } catch (error) {
        console.warn("Failed to get ownerCap:", error instanceof Error ? error.message : error);
        return null;
    }
}
