import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { MODULES } from "../utils/config";
import { deriveObjectId } from "../utils/derive-object-id";
import { GAME_CHARACTER_ID, GATE_ITEM_ID_1, GATE_ITEM_ID_2 } from "../utils/constants";
import {
    getEnvConfig,
    handleError,
    hydrateWorldConfig,
    initializeContext,
    requireEnv,
} from "../utils/helper";
import { requireBuilderPackageId } from "../utils/builder-extension";
import { getOwnerCap as getGateOwnerCap } from "../gate/helper";
import { MODULE as extensionModule } from "./modules";

const builderPackageId = requireBuilderPackageId();
const characterItemId = GAME_CHARACTER_ID;
const gateAItemId = GATE_ITEM_ID_1;
const gateBItemId = GATE_ITEM_ID_2;

async function authoriseGate(
    ctx: ReturnType<typeof initializeContext>,
    gateItemId: bigint,
    characterItemId: bigint
) {
    const { client, keypair, config, address } = ctx;

    const characterId = deriveObjectId(config.objectRegistry, characterItemId, config.packageId);
    const gateId = deriveObjectId(config.objectRegistry, gateItemId, config.packageId);

    const gateOwnerCapId = await getGateOwnerCap(gateId, client, config, address);
    if (!gateOwnerCapId) {
        throw new Error(`OwnerCap not found for gate ${gateId}`);
    }

    const authType = `${builderPackageId}::${extensionModule.CONFIG}::XAuth`;

    const tx = new Transaction();

    const [gateOwnerCap, receipt] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.GATE}::Gate`],
        arguments: [tx.object(characterId), tx.object(gateOwnerCapId)],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.GATE}::authorize_extension`,
        typeArguments: [authType],
        arguments: [tx.object(gateId), gateOwnerCap!],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::return_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.GATE}::Gate`],
        arguments: [tx.object(characterId), gateOwnerCap!, receipt],
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
        await authoriseGate(ctx, gateAItemId, BigInt(characterItemId));
        await authoriseGate(ctx, gateBItemId, BigInt(characterItemId));
    } catch (error) {
        handleError(error);
    }
}

main();
