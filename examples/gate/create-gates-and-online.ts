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
    shareHydratedConfig,
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
import { getOwnerCap } from "./helper";

async function createGates(
    ctx: ReturnType<typeof initializeContext>,
    nwnId: bigint,
    gateAItemId: bigint,
    gateBItemId: bigint,
    characterId: number
) {
    const { client, keypair, config } = ctx;
    const adminCap = await getAdminCapId(client, config.packageId);
    if (!adminCap) throw new Error("AdminCap not found (check ADMIN_ADDRESS / access setup)");

    const characterObjectId = deriveObjectId(config.objectRegistry, characterId, config.packageId);
    const networkNodeObjectId = deriveObjectId(config.objectRegistry, nwnId, config.packageId);

    const tx = new Transaction();

    const [gateA] = tx.moveCall({
        target: `${config.packageId}::${MODULES.GATE}::anchor`,
        arguments: [
            tx.object(config.objectRegistry),
            tx.object(networkNodeObjectId),
            tx.object(characterObjectId),
            tx.object(adminCap),
            tx.pure.u64(gateAItemId),
            tx.pure.u64(GATE_TYPE_ID),
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(LOCATION_HASH))),
        ],
    });

    const [gateB] = tx.moveCall({
        target: `${config.packageId}::${MODULES.GATE}::anchor`,
        arguments: [
            tx.object(config.objectRegistry),
            tx.object(networkNodeObjectId),
            tx.object(characterObjectId),
            tx.object(adminCap),
            tx.pure.u64(gateBItemId),
            tx.pure.u64(GATE_TYPE_ID),
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(LOCATION_HASH))),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.GATE}::share_gate`,
        arguments: [gateA, tx.object(adminCap)],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.GATE}::share_gate`,
        arguments: [gateB, tx.object(adminCap)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEvents: true, showEffects: true, showObjectChanges: true },
    });

    console.log(result);

    const gateEvent = extractEvent<{ assembly_id: string; owner_cap_id: string }>(
        result,
        "::gate::GateCreatedEvent"
    );
    if (gateEvent) {
        console.log("Gate created (one of them):", gateEvent);
    }

    const gateAId = deriveObjectId(config.objectRegistry, gateAItemId, config.packageId);
    const gateBId = deriveObjectId(config.objectRegistry, gateBItemId, config.packageId);
    console.log("Gate A Object Id:", gateAId);
    console.log("Gate B Object Id:", gateBId);
}

async function bringGatesOnline(
    ctx: ReturnType<typeof initializeContext>,
    characterId: number,
    nwnId: bigint,
    gateAItemId: bigint,
    gateBItemId: bigint
) {
    const { client, keypair, config, address } = ctx;

    const characterObjectId = deriveObjectId(config.objectRegistry, characterId, config.packageId);
    const networkNodeObjectId = deriveObjectId(config.objectRegistry, nwnId, config.packageId);
    const gateAId = deriveObjectId(config.objectRegistry, gateAItemId, config.packageId);
    const gateBId = deriveObjectId(config.objectRegistry, gateBItemId, config.packageId);

    const gateAOwnerCapId = await getOwnerCap(gateAId, client, config, address);
    const gateBOwnerCapId = await getOwnerCap(gateBId, client, config, address);
    if (!gateAOwnerCapId || !gateBOwnerCapId) {
        throw new Error("Gate OwnerCaps not found (make sure the character owns both gates)");
    }

    const tx = new Transaction();

    const [gateAOwnerCap] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.GATE}::Gate`],
        arguments: [tx.object(characterObjectId), tx.object(gateAOwnerCapId)],
    });

    const [gateBOwnerCap] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.GATE}::Gate`],
        arguments: [tx.object(characterObjectId), tx.object(gateBOwnerCapId)],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.GATE}::online`,
        arguments: [
            tx.object(gateAId),
            tx.object(networkNodeObjectId),
            tx.object(config.energyConfig),
            gateAOwnerCap,
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.GATE}::online`,
        arguments: [
            tx.object(gateBId),
            tx.object(networkNodeObjectId),
            tx.object(config.energyConfig),
            gateBOwnerCap,
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::return_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.GATE}::Gate`],
        arguments: [tx.object(characterObjectId), gateAOwnerCap],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::return_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.GATE}::Gate`],
        arguments: [tx.object(characterObjectId), gateBOwnerCap],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true, showEvents: true },
    });

    console.log("\nGates brought online successfully!");
    console.log("Transaction digest:", result.digest);
}

async function main() {
    try {
        const env = getEnvConfig();

        const adminCtx = initializeContext(env.network, env.adminExportedKey);
        await hydrateWorldConfig(adminCtx);
        await createGates(adminCtx, NWN_ITEM_ID, GATE_ITEM_ID_1, GATE_ITEM_ID_2, GAME_CHARACTER_ID);

        const playerKey = process.env.PLAYER_A_PRIVATE_KEY;
        const playerAddress = process.env.PLAYER_ADDRESS;
        const playerCtx = initializeContext(env.network, playerKey!);
        shareHydratedConfig(adminCtx, playerCtx);
        await bringGatesOnline(
            playerCtx,
            GAME_CHARACTER_ID,
            NWN_ITEM_ID,
            GATE_ITEM_ID_1,
            GATE_ITEM_ID_2
        );
    } catch (error) {
        handleError(error);
    }
}

main().catch(console.error);
