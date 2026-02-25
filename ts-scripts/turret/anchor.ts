import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { HydratedWorldConfig, MODULES } from "../utils/config";
import {
    initializeContext,
    handleError,
    extractEvent,
    hexToBytes,
    getEnvConfig,
    hydrateWorldConfig,
} from "../utils/helper";
import {
    LOCATION_HASH,
    GAME_CHARACTER_ID,
    TURRET_TYPE_ID,
    TURRET_ITEM_ID,
    NWN_ITEM_ID,
} from "../utils/constants";
import { deriveObjectId } from "../utils/derive-object-id";

async function anchorTurret(
    characterObjectId: string,
    networkNodeObjectId: string,
    typeId: bigint,
    itemId: bigint,
    ctx: ReturnType<typeof initializeContext>
) {
    const { client, keypair } = ctx;
    const config = ctx.config as HydratedWorldConfig;
    const adminAcl = config.adminAcl;
    const tx = new Transaction();

    const [turret] = tx.moveCall({
        target: `${config.packageId}::${MODULES.TURRET}::anchor`,
        arguments: [
            tx.object(config.objectRegistry),
            tx.object(networkNodeObjectId),
            tx.object(characterObjectId),
            tx.object(adminAcl),
            tx.pure.u64(itemId),
            tx.pure.u64(typeId),
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(LOCATION_HASH))),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.TURRET}::share_turret`,
        arguments: [turret, tx.object(adminAcl)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEvents: true },
    });

    const event = extractEvent<{ turret_id: string; owner_cap_id: string; type_id: string }>(
        result,
        "::turret::TurretCreatedEvent"
    );
    if (!event) {
        throw new Error("TurretCreatedEvent not found in transaction result");
    }
    console.log("Turret Object Id:", event.turret_id);
    console.log("OwnerCap Object Id:", event.owner_cap_id);
    return result;
}

async function main() {
    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.adminExportedKey);
        await hydrateWorldConfig(ctx);

        const characterObjectId = deriveObjectId(
            ctx.config.objectRegistry,
            GAME_CHARACTER_ID,
            ctx.config.packageId
        );
        const networkNodeObjectId = deriveObjectId(
            ctx.config.objectRegistry,
            NWN_ITEM_ID,
            ctx.config.packageId
        );

        await anchorTurret(
            characterObjectId,
            networkNodeObjectId,
            TURRET_TYPE_ID,
            TURRET_ITEM_ID,
            ctx
        );
    } catch (error) {
        handleError(error);
    }
}

main();
