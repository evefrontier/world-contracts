import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { MODULES } from "../utils/config";
import { deriveObjectId } from "../utils/derive-object-id";
import {
    GATE_ITEM_ID_1,
    GATE_ITEM_ID_2,
    CLOCK_OBJECT_ID,
    ITEM_A_TYPE_ID,
    STORAGE_A_ITEM_ID,
    GAME_CHARACTER_B_ID,
    LOCATION_HASH,
} from "../utils/constants";
import {
    getEnvConfig,
    handleError,
    hexToBytes,
    hydrateWorldConfig,
    initializeContext,
    requireEnv,
} from "../utils/helper";
import { resolveBuilderGateExtensionIds } from "../utils/builder-extension";
import { MODULE as extensionModule } from "./modules";
import { getCharacterOwnerCap } from "../character/helper";
import { keypairFromPrivateKey } from "../utils/client";
import { generateLocationProof } from "../utils/proof";

async function collectCorpseBounty(
    ctx: ReturnType<typeof initializeContext>,
    sourceGateItemId: bigint,
    destinationGateItemId: bigint,
    storageUnitItemId: bigint,
    characterItemId: bigint,
    proofHex: string
) {
    const { client, keypair, config, address } = ctx;

    const { builderPackageId, extensionConfigId } = resolveBuilderGateExtensionIds({
        adminAddressOwner: requireEnv("ADMIN_ADDRESS"),
    });

    const sourceGateId = deriveObjectId(config.objectRegistry, sourceGateItemId, config.packageId);
    const destinationGateId = deriveObjectId(
        config.objectRegistry,
        destinationGateItemId,
        config.packageId
    );
    const characterId = deriveObjectId(config.objectRegistry, characterItemId, config.packageId);
    const storageUnitId = deriveObjectId(
        config.objectRegistry,
        storageUnitItemId,
        config.packageId
    );

    // Ephemeral inventory is owned by the character
    const playerOwnerCapId = await getCharacterOwnerCap(characterId, client, config, address);
    if (!playerOwnerCapId) {
        throw new Error(`OwnerCap not found for ${characterId}`);
    }

    const tx = new Transaction();

    const [ownerCap, receipt] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.CHARACTER}::Character`],
        arguments: [tx.object(characterId), tx.object(playerOwnerCapId)],
    });

    tx.moveCall({
        target: `${builderPackageId}::${extensionModule.CORPSE_GATE_BOUNTY}::collect_corpse_bounty`,
        typeArguments: [`${config.packageId}::${MODULES.CHARACTER}::Character`],
        arguments: [
            tx.object(extensionConfigId),
            tx.object(storageUnitId),
            tx.object(config.serverAddressRegistry),
            tx.object(sourceGateId!),
            tx.object(destinationGateId!),
            tx.object(characterId!),
            ownerCap,
            tx.pure.u64(ITEM_A_TYPE_ID),
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(proofHex))),
            tx.object(CLOCK_OBJECT_ID),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::return_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.CHARACTER}::Character`],
        arguments: [tx.object(characterId), ownerCap, receipt],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEffects: true, showObjectChanges: true, showEvents: true },
    });

    console.log("\nCorpse bounty collected + JumpPermit issued!");
    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    console.log("============= Collect Corpse Bounty ==============\n");
    try {
        const env = getEnvConfig();
        const playerKey = requireEnv("PLAYER_B_PRIVATE_KEY");
        const ctx = initializeContext(env.network, playerKey);
        await hydrateWorldConfig(ctx);

        const characterId = deriveObjectId(
            ctx.config.objectRegistry,
            BigInt(GAME_CHARACTER_B_ID),
            ctx.config.packageId
        );
        const storageUnitId = deriveObjectId(
            ctx.config.objectRegistry,
            STORAGE_A_ITEM_ID,
            ctx.config.packageId
        );

        const adminKeypair = keypairFromPrivateKey(requireEnv("ADMIN_PRIVATE_KEY"));
        const proofHex = await generateLocationProof(
            adminKeypair,
            ctx.address,
            characterId,
            storageUnitId,
            LOCATION_HASH
        );

        await collectCorpseBounty(
            ctx,
            GATE_ITEM_ID_1,
            GATE_ITEM_ID_2,
            STORAGE_A_ITEM_ID,
            BigInt(GAME_CHARACTER_B_ID),
            proofHex
        );
    } catch (error) {
        handleError(error);
    }
}

main();
