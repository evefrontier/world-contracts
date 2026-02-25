import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { HydratedWorldConfig, MODULES } from "../utils/config";
import { GAME_CHARACTER_ID, NWN_ITEM_ID, TURRET_ITEM_ID } from "../utils/constants";
import { deriveObjectId } from "../utils/derive-object-id";
import {
    getEnvConfig,
    handleError,
    hydrateWorldConfig,
    initializeContext,
    requireEnv,
} from "../utils/helper";
import { getOwnerCap } from "./helper";

async function onlineTurret(
    turretId: string,
    networkNodeId: string,
    ownerCapId: string,
    ctx: ReturnType<typeof initializeContext>
) {
    const { client, keypair } = ctx;
    const config = ctx.config as HydratedWorldConfig;
    const characterId = deriveObjectId(config.objectRegistry, GAME_CHARACTER_ID, config.packageId);

    const tx = new Transaction();

    const [ownerCap, receipt] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.TURRET}::Turret`],
        arguments: [tx.object(characterId), tx.object(ownerCapId)],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.TURRET}::online`,
        arguments: [
            tx.object(turretId),
            tx.object(networkNodeId),
            tx.object(config.energyConfig),
            ownerCap,
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::return_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.TURRET}::Turret`],
        arguments: [tx.object(characterId), ownerCap, receipt],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEffects: true, showObjectChanges: true },
    });
    console.log("Turret brought online. Digest:", result.digest);
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
        const networkNodeId = deriveObjectId(
            ctx.config.objectRegistry,
            NWN_ITEM_ID,
            ctx.config.packageId
        );

        const ownerCapId = await getOwnerCap(turretId, ctx.client, ctx.config, ctx.address);
        if (!ownerCapId) {
            throw new Error(`OwnerCap not found for turret ${turretId}`);
        }

        await onlineTurret(turretId, networkNodeId, ownerCapId, ctx);
    } catch (error) {
        handleError(error);
    }
}

main();
