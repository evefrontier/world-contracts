import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { MODULES } from "../utils/config";
import { deriveObjectId } from "../utils/derive-object-id";
import {
    GAME_CHARACTER_B_ID,
    GATE_ITEM_ID_1,
    GATE_ITEM_ID_2,
    CLOCK_OBJECT_ID,
} from "../utils/constants";
import { getEnvConfig, handleError, hydrateWorldConfig, initializeContext } from "../utils/helper";
import { resolveBuilderGateExtensionIds } from "../utils/builder-extension";
import { MODULE as extensionModule } from "./modules";

async function issueJumpPermit(
    ctx: ReturnType<typeof initializeContext>,
    sourceGateItemId: bigint,
    destinationGateItemId: bigint,
    characterItemId: bigint
) {
    const { client, keypair, config, address } = ctx;

    const { builderPackageId, adminCapId, extensionConfigId } = resolveBuilderGateExtensionIds({
        adminAddressOwner: address,
    });

    const sourceGateId = deriveObjectId(config.objectRegistry, sourceGateItemId, config.packageId);
    const destinationGateId = deriveObjectId(
        config.objectRegistry,
        destinationGateItemId,
        config.packageId
    );
    const characterId = deriveObjectId(config.objectRegistry, characterItemId, config.packageId);

    const tx = new Transaction();
    tx.moveCall({
        target: `${builderPackageId}::${extensionModule.TRIBE_PERMIT}::issue_jump_permit`,
        arguments: [
            tx.object(extensionConfigId),
            tx.object(sourceGateId),
            tx.object(destinationGateId),
            tx.object(characterId),
            tx.object(adminCapId),
            tx.object(CLOCK_OBJECT_ID),
        ],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEffects: true, showObjectChanges: true, showEvents: true },
    });

    console.log("\nJumpPermit issued!");
    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    console.log("============= Issue Jump Permit ==============\n");
    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.adminExportedKey);
        await hydrateWorldConfig(ctx);
        await issueJumpPermit(ctx, GATE_ITEM_ID_1, GATE_ITEM_ID_2, BigInt(GAME_CHARACTER_B_ID));
    } catch (error) {
        handleError(error);
    }
}

main();
