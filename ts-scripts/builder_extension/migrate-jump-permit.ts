import "dotenv/config";
import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Transaction } from "@mysten/sui/transactions";
import { MODULES } from "../utils/config";
import { deriveObjectId } from "../utils/derive-object-id";
import {
    extractEvent,
    getEnvConfig,
    handleError,
    hydrateWorldConfig,
    initializeContext,
    requireEnv,
} from "../utils/helper";
import {
    CLOCK_OBJECT_ID,
    GAME_CHARACTER_B_ID,
    GATE_ITEM_ID_1,
    GATE_ITEM_ID_2,
} from "../utils/constants";
import { MODULE as extensionModule } from "./modules";

const BUILDER_PACKAGE_LATEST = process.env.UPGRADED_BUILDER_PACKAGE_ID || "";

async function getOwnedLegacyJumpPermitIds(
    client: SuiJsonRpcClient,
    owner: string,
    worldPackageId: string
): Promise<string[]> {
    const type = `${worldPackageId}::${MODULES.GATE}::JumpPermit`;
    const ids: string[] = [];
    let cursor: string | null | undefined;
    do {
        const res = await client.getOwnedObjects({
            owner,
            filter: { StructType: type },
            cursor: cursor ?? undefined,
        });
        for (const obj of res.data) {
            const id = obj.data?.objectId;
            if (id) ids.push(id);
        }
        cursor = res.hasNextPage ? res.nextCursor : undefined;
    } while (cursor);
    return ids;
}

async function migrateJumpPermit(
    ctx: ReturnType<typeof initializeContext>,
    characterItemId: bigint,
    sourceGateItemId: bigint,
    destinationGateItemId: bigint
) {
    const { client, keypair, config, address } = ctx;

    if (!BUILDER_PACKAGE_LATEST) {
        throw new Error(
            "Set UPGRADED_BUILDER_PACKAGE_ID; the migrate_jump_permit entry lives on the upgraded builder package."
        );
    }

    const legacyPermitIds = await getOwnedLegacyJumpPermitIds(client, address, config.packageId);
    if (legacyPermitIds.length === 0) {
        console.log("No legacy JumpPermit objects to migrate for", address);
        return;
    }
    console.log(`Found ${legacyPermitIds.length} legacy JumpPermit(s) to migrate`);

    const characterId = deriveObjectId(config.objectRegistry, characterItemId, config.packageId);
    const sourceGateId = deriveObjectId(config.objectRegistry, sourceGateItemId, config.packageId);
    const destinationGateId = deriveObjectId(
        config.objectRegistry,
        destinationGateItemId,
        config.packageId
    );

    for (const legacyPermitId of legacyPermitIds) {
        const tx = new Transaction();
        tx.setGasBudget(100_000_000);
        tx.moveCall({
            target: `${BUILDER_PACKAGE_LATEST}::${extensionModule.TRIBE_PERMIT}::migrate_jump_permit`,
            arguments: [
                tx.object(sourceGateId),
                tx.object(destinationGateId),
                tx.object(characterId),
                tx.object(legacyPermitId),
                tx.object(CLOCK_OBJECT_ID),
            ],
        });

        const result = await client.signAndExecuteTransaction({
            transaction: tx,
            signer: keypair,
            options: { showEffects: true, showObjectChanges: true, showEvents: true },
        });

        const migratedEvent = extractEvent<{
            legacy_jump_permit_id: string;
            new_jump_permit_id: string;
            extension_type: { name: string };
        }>(result, "::gate::JumpPermitMigratedEvent");

        console.log(`Migrated ${legacyPermitId} -> ${migratedEvent?.new_jump_permit_id ?? "?"}`);
        console.log("  digest:", result.digest);
    }
}

async function main() {
    console.log("============= Migrate Legacy JumpPermit -> JumpPermitV2 ==============\n");
    try {
        const env = getEnvConfig();
        const playerKey = requireEnv("PLAYER_B_PRIVATE_KEY");
        const ctx = initializeContext(env.network, playerKey);
        await hydrateWorldConfig(ctx);

        await migrateJumpPermit(ctx, BigInt(GAME_CHARACTER_B_ID), GATE_ITEM_ID_1, GATE_ITEM_ID_2);
    } catch (error) {
        handleError(error);
    }
}

main();
