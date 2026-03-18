import "dotenv/config";
import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Transaction } from "@mysten/sui/transactions";
import { MODULES } from "../utils/config";
import {
    getEnvConfig,
    handleError,
    hydrateWorldConfig,
    initializeContext,
    requireEnv,
} from "../utils/helper";

// Upgraded world package ID (published-at from Move.toml)
const WORLD_PACKAGE_LATEST = process.env.UPGRADED_WORLD_PACKAGE_ID || "";

async function getOwnedJumpPermitId(
    client: SuiJsonRpcClient,
    owner: string,
    worldPackageId: string
): Promise<string | null> {
    const type = `${worldPackageId}::${MODULES.GATE}::JumpPermit`;
    const res = await client.getOwnedObjects({
        owner,
        filter: { StructType: type },
        limit: 1,
    });
    const first = res.data?.[0]?.data;
    return first?.objectId ?? null;
}

async function deleteJumpPermit(ctx: ReturnType<typeof initializeContext>) {
    const { client, keypair, config, address } = ctx;

    const jumpPermitId = await getOwnedJumpPermitId(client, address, config.packageId);
    if (!jumpPermitId) {
        throw new Error("You should own a JumpPermit object to delete it");
    }
    console.log(jumpPermitId);
    if (!WORLD_PACKAGE_LATEST) {
        throw new Error(
            "Set UPGRADED_WORLD_PACKAGE_ID for the move call (delete_jump_permit exists only on upgraded package)."
        );
    }
    const tx = new Transaction();
    tx.setGasBudget(100_000_000);
    tx.moveCall({
        target: `${WORLD_PACKAGE_LATEST}::${MODULES.GATE}::delete_jump_permit`,
        arguments: [tx.object(jumpPermitId)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEffects: true, showObjectChanges: true, showEvents: true },
    });

    console.log("JumpPermit deleted:", jumpPermitId);
    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    console.log("============= Delete Jump Permit (owner direct) ==============\n");
    try {
        const env = getEnvConfig();
        const playerKey = requireEnv("PLAYER_B_PRIVATE_KEY");
        const ctx = initializeContext(env.network, playerKey);
        await hydrateWorldConfig(ctx);
        await deleteJumpPermit(ctx);
    } catch (error) {
        handleError(error);
    }
}

main();
