import "dotenv/config";
import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Transaction } from "@mysten/sui/transactions";
import { MODULES } from "../utils/config";
import { deriveObjectId } from "../utils/derive-object-id";
import {
    getEnvConfig,
    handleError,
    hydrateWorldConfig,
    initializeContext,
    requireEnv,
} from "../utils/helper";
import { GATE_ITEM_ID_1 } from "../utils/constants";
import { MODULE as extensionModule } from "./modules";

// Upgraded builder package ID (published-at from Move.toml)
const BUILDER_PACKAGE_LATEST = process.env.UPGRADED_BUILDER_PACKAGE_ID || "";

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

async function voidJumpPermitViaExtension(ctx: ReturnType<typeof initializeContext>) {
    const { client, keypair, config, address } = ctx;

    const jumpPermitId = await getOwnedJumpPermitId(client, address, config.packageId);
    if (!jumpPermitId) {
        throw new Error("You should own a JumpPermit object to void it via the extension");
    }

    if (!BUILDER_PACKAGE_LATEST) {
        throw new Error(
            "Set UPGRADED_BUILDER_PACKAGE_ID for the move call (extension lives on upgraded builder package)."
        );
    }
    const sourceGateId = deriveObjectId(config.objectRegistry, GATE_ITEM_ID_1, config.packageId);

    const tx = new Transaction();
    tx.setGasBudget(100_000_000);
    tx.moveCall({
        target: `${BUILDER_PACKAGE_LATEST}::${extensionModule.TRIBE_PERMIT}::delete_jump_permit`,
        arguments: [tx.object(sourceGateId), tx.object(jumpPermitId)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEffects: true, showObjectChanges: true, showEvents: true },
    });

    console.log("JumpPermit deleted via extension (tribe_permit):", jumpPermitId);
    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    console.log("============= Delete Jump Permit (owner via extension) ==============\n");
    try {
        const env = getEnvConfig();
        const playerKey = requireEnv("PLAYER_B_PRIVATE_KEY");
        const ctx = initializeContext(env.network, playerKey);
        await hydrateWorldConfig(ctx);
        await voidJumpPermitViaExtension(ctx);
    } catch (error) {
        handleError(error);
    }
}

main();
