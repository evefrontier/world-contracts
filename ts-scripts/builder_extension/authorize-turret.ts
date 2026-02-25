import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { MODULES } from "../utils/config";
import { deriveObjectId } from "../utils/derive-object-id";
import { GAME_CHARACTER_ID, TURRET_ITEM_ID } from "../utils/constants";
import {
    getEnvConfig,
    handleError,
    hydrateWorldConfig,
    initializeContext,
    requireEnv,
} from "../utils/helper";
import { getOwnerCap } from "../turret/helper";
import { requireBuilderPackageId } from "../utils/builder-extension";
import { MODULE as extensionModule } from "./modules";

const builderPackageId = requireBuilderPackageId();

async function authorizeExtension(
    ctx: ReturnType<typeof initializeContext>,
    turretId: string,
    authType: string
) {
    const { client, keypair } = ctx;
    const characterId = deriveObjectId(
        ctx.config.objectRegistry,
        GAME_CHARACTER_ID,
        ctx.config.packageId
    );
    const ownerCapId = await getOwnerCap(turretId, client, ctx.config, ctx.address);
    if (!ownerCapId) {
        throw new Error(`OwnerCap not found for turret ${turretId}`);
    }

    const tx = new Transaction();

    const [ownerCap, receipt] = tx.moveCall({
        target: `${ctx.config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${ctx.config.packageId}::${MODULES.TURRET}::Turret`],
        arguments: [tx.object(characterId), tx.object(ownerCapId)],
    });

    tx.moveCall({
        target: `${ctx.config.packageId}::${MODULES.TURRET}::authorize_extension`,
        typeArguments: [authType],
        arguments: [tx.object(turretId), ownerCap],
    });

    tx.moveCall({
        target: `${ctx.config.packageId}::${MODULES.CHARACTER}::return_owner_cap`,
        typeArguments: [`${ctx.config.packageId}::${MODULES.TURRET}::Turret`],
        arguments: [tx.object(characterId), ownerCap, receipt],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEffects: true, showObjectChanges: true, showEvents: true },
    });
    console.log("Extension authorized. Auth type:", authType);
    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    try {
        const env = getEnvConfig();
        const playerKey = requireEnv("PLAYER_A_PRIVATE_KEY");
        const ctx = initializeContext(env.network, playerKey);
        await hydrateWorldConfig(ctx);

        const turretId = deriveObjectId(
            ctx.config.objectRegistry,
            TURRET_ITEM_ID,
            ctx.config.packageId
        );
        const authType = `${builderPackageId}::${extensionModule.TURRET}::TurretAuth`;

        await authorizeExtension(ctx, turretId, authType);
    } catch (error) {
        handleError(error);
    }
}

main();
