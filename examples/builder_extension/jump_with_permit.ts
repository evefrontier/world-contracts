import "dotenv/config";
import { SuiClient } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";
import { MODULES } from "../utils/config";
import { deriveObjectId } from "../utils/derive-object-id";
import {
    GAME_CHARACTER_ID,
    GATE_ITEM_ID_1,
    GATE_ITEM_ID_2,
    CLOCK_OBJECT_ID,
} from "../utils/constants";
import {
    extractEvent,
    getEnvConfig,
    handleError,
    hydrateWorldConfig,
    initializeContext,
} from "../utils/helper";

function requireNonEmpty(value: string, name: string): string {
    if (!value) throw new Error(`${name} is required`);
    return value;
}

async function getOwnedJumpPermitId(
    client: SuiClient,
    owner: string,
    worldPackageId: string
): Promise<string | null> {
    const type = `${worldPackageId}::${MODULES.GATE}::JumpPermit`;
    const res = await client.getOwnedObjects({
        owner,
        filter: { StructType: type },
        limit: 1,
    });
    const first = res.data?.[0]?.data;
    return first?.objectId ?? null;
}

async function jumpWithPermit(ctx: ReturnType<typeof initializeContext>) {
    const { client, keypair, config, address } = ctx;

    const characterId =
        process.env.CHARACTER_ID ||
        deriveObjectId(config.objectRegistry, GAME_CHARACTER_ID, config.packageId);
    const sourceGateId =
        process.env.SOURCE_GATE_ID ||
        deriveObjectId(config.objectRegistry, GATE_ITEM_ID_1, config.packageId);
    const destinationGateId =
        process.env.DESTINATION_GATE_ID ||
        deriveObjectId(config.objectRegistry, GATE_ITEM_ID_2, config.packageId);

    const jumpPermitId = await getOwnedJumpPermitId(client, address, config.packageId);
    requireNonEmpty(jumpPermitId || "", "You should own a JumpPermit object");

    const tx = new Transaction();
    tx.moveCall({
        target: `${config.packageId}::${MODULES.GATE}::jump_with_permit`,
        arguments: [
            tx.object(sourceGateId),
            tx.object(destinationGateId),
            tx.object(characterId),
            tx.object(jumpPermitId!),
            tx.object(CLOCK_OBJECT_ID),
        ],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEvents: true, showEffects: true, showObjectChanges: true },
    });

    console.log("JumpPermit:", jumpPermitId);
    console.log("Transaction digest:", result.digest);

    const jumpEvent = extractEvent<{
        source_gate_id: string;
        destination_gate_id: string;
        character_id: string;
    }>(result, "::gate::JumpEvent");

    if (jumpEvent) {
        console.log("JumpEvent:", jumpEvent);
    }

    return result;
}

async function main() {
    console.log("============= Jump With JumpPermit ==============\n");
    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.playerExportedKey!);
        await hydrateWorldConfig(ctx);
        await jumpWithPermit(ctx);
    } catch (error) {
        handleError(error);
    }
}

main().catch(console.error);
