import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { MODULES } from "../utils/config";
import {
    extractEvent,
    getAdminCapId,
    getEnvConfig,
    handleError,
    hexToBytes,
    hydrateWorldConfig,
    initializeContext,
} from "../utils/helper";
import {
    GAME_CHARACTER_ID,
    GATE_ITEM_ID_1,
    GATE_ITEM_ID_2,
    GATE_TYPE_ID,
    LOCATION_HASH,
    NWN_ITEM_ID,
} from "../utils/constants";
import { deriveObjectId } from "../utils/derive-object-id";

async function createGate(
    ctx: ReturnType<typeof initializeContext>,
    nwnId: bigint,
    gateItemId: bigint,
    characterId: number
) {
    const { client, keypair, config } = ctx;
    const adminCap = await getAdminCapId(client, config.packageId);
    if (!adminCap) throw new Error("AdminCap not found");

    const characterObjectId = deriveObjectId(config.objectRegistry, characterId, config.packageId);
    const networkNodeObjectId = deriveObjectId(config.objectRegistry, nwnId, config.packageId);

    const tx = new Transaction();

    const [gate] = tx.moveCall({
        target: `${config.packageId}::${MODULES.GATE}::anchor`,
        arguments: [
            tx.object(config.objectRegistry),
            tx.object(networkNodeObjectId),
            tx.object(characterObjectId),
            tx.object(adminCap),
            tx.pure.u64(gateItemId),
            tx.pure.u64(GATE_TYPE_ID),
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(LOCATION_HASH))),
        ],
    });
    tx.moveCall({
        target: `${config.packageId}::${MODULES.GATE}::share_gate`,
        arguments: [gate, tx.object(adminCap)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEvents: true, showEffects: true, showObjectChanges: true },
    });

    const gateEvent = extractEvent<{ assembly_id: string; owner_cap_id: string }>(
        result,
        "::gate::GateCreatedEvent"
    );
    if (gateEvent) {
        console.log("Gate created (one of them):", gateEvent);
    }

    const gateId = deriveObjectId(config.objectRegistry, gateItemId, config.packageId);
    console.log("Gate Object Id:", gateId);
}

async function main() {
    try {
        const env = getEnvConfig();

        const adminCtx = initializeContext(env.network, env.adminExportedKey);
        await hydrateWorldConfig(adminCtx);
        await createGate(adminCtx, NWN_ITEM_ID, GATE_ITEM_ID_1, GAME_CHARACTER_ID);
        await createGate(adminCtx, NWN_ITEM_ID, GATE_ITEM_ID_2, GAME_CHARACTER_ID);
    } catch (error) {
        handleError(error);
    }
}

main();
