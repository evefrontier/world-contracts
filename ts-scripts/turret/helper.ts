import { bcs } from "@mysten/sui/bcs";
import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { getConfig, MODULES } from "../utils/config";
import { devInspectMoveCallFirstReturnValueBytes } from "../utils/dev-inspect";

export async function getOwnerCap(
    turretId: string,
    client: SuiJsonRpcClient,
    config: ReturnType<typeof getConfig>,
    senderAddress?: string
): Promise<string | null> {
    try {
        const bytes = await devInspectMoveCallFirstReturnValueBytes(client, {
            target: `${config.packageId}::${MODULES.TURRET}::owner_cap_id`,
            senderAddress,
            arguments: (tx) => [tx.object(turretId)],
        });
        if (!bytes) return null;
        return bcs.Address.parse(bytes);
    } catch (error) {
        console.warn(
            "Failed to get turret OwnerCap:",
            error instanceof Error ? error.message : error
        );
        return null;
    }
}
