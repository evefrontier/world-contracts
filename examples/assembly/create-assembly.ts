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
    getAdminCapId,
    hydrateWorldConfig,
} from "../utils/helper";
import {
    LOCATION_HASH,
    GAME_CHARACTER_ID,
    NWN_ITEM_ID,
    ASSEMBLY_TYPE_ID,
    ASSEMBLY_ITEM_ID,
} from "../utils/constants";
import { deriveObjectId } from "../utils/derive-object-id";

async function createAssembly(
    characterObjectId: string,
    networkNodeObjectId: string,
    typeId: bigint,
    itemId: bigint,
    ctx: ReturnType<typeof initializeContext>
) {
    const { client, keypair } = ctx;
    const config = ctx.config as HydratedWorldConfig;
    const adminCap = await getAdminCapId(client, config.packageId);
    if (!adminCap) throw new Error("AdminCap not found");
    const tx = new Transaction();

    const [assembly] = tx.moveCall({
        target: `${config.packageId}::${MODULES.ASSEMBLY}::anchor`,
        arguments: [
            tx.object(config.objectRegistry),
            tx.object(networkNodeObjectId),
            tx.object(characterObjectId),
            tx.object(adminCap),
            tx.pure.u64(itemId),
            tx.pure.u64(typeId),
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(LOCATION_HASH))),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.ASSEMBLY}::share_assembly`,
        arguments: [assembly, tx.object(adminCap)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEvents: true },
    });

    const assemblyEvent = extractEvent<{ assembly_id: string; owner_cap_id: string }>(
        result,
        "::assembly::AssemblyCreatedEvent"
    );

    if (!assemblyEvent) {
        throw new Error("AssemblyCreatedEvent not found in transaction result");
    }

    console.log("Assembly Object Id: ", assemblyEvent.assembly_id);
    console.log("OwnerCap Object Id: ", assemblyEvent.owner_cap_id);
}

async function main() {
    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.adminExportedKey);
        const config = await hydrateWorldConfig(ctx);
        ctx.config = config;

        const characterObject = deriveObjectId(
            config.objectRegistry,
            GAME_CHARACTER_ID,
            config.packageId
        );
        const networkNodeObject = deriveObjectId(
            config.objectRegistry,
            NWN_ITEM_ID,
            config.packageId
        );

        await createAssembly(
            characterObject,
            networkNodeObject,
            ASSEMBLY_TYPE_ID,
            ASSEMBLY_ITEM_ID,
            ctx
        );
    } catch (error) {
        handleError(error);
    }
}

main();
