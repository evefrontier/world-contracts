import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { MODULES } from "../utils/config";
import { deriveObjectId } from "../utils/derive-object-id";
import { GAME_CHARACTER_ID, STORAGE_A_ITEM_ID } from "../utils/constants";
import {
    getEnvConfig,
    handleError,
    hydrateWorldConfig,
    initializeContext,
    requireEnv,
} from "../utils/helper";
import { requireBuilderPackageId } from "../utils/builder-extension";
import { getOwnerCap as getStorageUnitOwnerCap } from "../storage-unit/helper";
import { MODULE as extensionModule } from "./modules";

const builderPackageId = requireBuilderPackageId();
const characterItemId = GAME_CHARACTER_ID;
const storageUnitItemId = STORAGE_A_ITEM_ID;

async function authoriseStorageUnit(
    ctx: ReturnType<typeof initializeContext>,
    storageUnitItemId: bigint,
    characterItemId: bigint
) {
    const { client, keypair, config, address } = ctx;

    const characterId = deriveObjectId(config.objectRegistry, characterItemId, config.packageId);
    const storageUnitId = deriveObjectId(
        config.objectRegistry,
        storageUnitItemId,
        config.packageId
    );

    const storageUnitOwnerCapId = await getStorageUnitOwnerCap(
        storageUnitId,
        client,
        config,
        address
    );
    if (!storageUnitOwnerCapId) {
        throw new Error(`OwnerCap not found for storage unit ${storageUnitId}`);
    }

    const authType = `${builderPackageId}::${extensionModule.CONFIG}::XAuth`;

    const tx = new Transaction();

    const [storageUnitOwnerCap, receipt] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.STORAGE_UNIT}::StorageUnit`],
        arguments: [tx.object(characterId), tx.object(storageUnitOwnerCapId)],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::authorize_extension`,
        typeArguments: [authType],
        arguments: [tx.object(storageUnitId), storageUnitOwnerCap],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::return_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.STORAGE_UNIT}::StorageUnit`],
        arguments: [tx.object(characterId), storageUnitOwnerCap, receipt],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEffects: true, showObjectChanges: true, showEvents: true },
    });

    console.log("\nExtension authorized successfully!");
    console.log("Auth type:", authType);
    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    try {
        const env = getEnvConfig();
        const playerKey = requireEnv("PLAYER_A_PRIVATE_KEY");
        const ctx = initializeContext(env.network, playerKey);
        await hydrateWorldConfig(ctx);
        await authoriseStorageUnit(ctx, storageUnitItemId, BigInt(characterItemId));
    } catch (error) {
        handleError(error);
    }
}

main();
