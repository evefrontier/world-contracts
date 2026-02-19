import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { MODULES } from "../utils/config";
import {
    initializeContext,
    handleError,
    extractEvent,
    hexToBytes,
    getEnvConfig,
    hydrateWorldConfig,
} from "../utils/helper";
import { deriveObjectId } from "../utils/derive-object-id";
import { LOCATION_HASH, GAME_CHARACTER_ID, NWN_TYPE_ID, NWN_ITEM_ID } from "../utils/constants";

export const FUEL_MAX_CAPACITY = 10000n;
export const FUEL_BURN_RATE_IN_MS = BigInt(3600 * 1000); // 1 hour
export const MAX_ENERGY_PRODUCTION = 100n;

async function createNetworkNode(
    characterObjectId: string,
    typeId: bigint,
    itemId: bigint,
    ctx: ReturnType<typeof initializeContext>
) {
    const { client, keypair, config } = ctx;
    const adminAcl = config.adminAcl;
    const tx = new Transaction();

    const [nwn] = tx.moveCall({
        target: `${config.packageId}::${MODULES.NETWORK_NODE}::anchor`,
        arguments: [
            tx.object(config.objectRegistry),
            tx.object(characterObjectId),
            tx.object(adminAcl),
            tx.pure.u64(itemId),
            tx.pure.u64(typeId),
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(LOCATION_HASH))),
            tx.pure.u64(FUEL_MAX_CAPACITY),
            tx.pure.u64(FUEL_BURN_RATE_IN_MS),
            tx.pure.u64(MAX_ENERGY_PRODUCTION),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.NETWORK_NODE}::share_network_node`,
        arguments: [nwn, tx.object(adminAcl)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEvents: true },
    });

    const networkNodeEvent = extractEvent<{ network_node_id: string; owner_cap_id: string }>(
        result,
        "::network_node::NetworkNodeCreatedEvent"
    );

    if (!networkNodeEvent) {
        throw new Error("NetworkNodeCreatedEvent not found in transaction result");
    }

    console.log("NWN Object Id: ", networkNodeEvent.network_node_id);
    console.log("OwnerCap Object Id: ", networkNodeEvent.owner_cap_id);
}

async function main() {
    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.adminExportedKey);
        await hydrateWorldConfig(ctx);

        const characterObject = deriveObjectId(
            ctx.config.objectRegistry,
            GAME_CHARACTER_ID,
            ctx.config.packageId
        );

        await createNetworkNode(characterObject, NWN_TYPE_ID, NWN_ITEM_ID, ctx);
    } catch (error) {
        handleError(error);
    }
}

main();
