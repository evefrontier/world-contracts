import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES } from "../utils/config";
import { deriveObjectId } from "../utils/derive-object-id";
import {
    hydrateWorldConfig,
    initializeContext,
    handleError,
    getEnvConfig,
    shareHydratedConfig,
    requireEnv,
} from "../utils/helper";
import { executeSponsoredTransaction } from "../utils/transaction";
import {
    GAME_CHARACTER_B_ID,
    STORAGE_A_ITEM_ID,
    ITEM_A_TYPE_ID,
    ITEM_A_ITEM_ID,
} from "../utils/constants";
import { getCharacterOwnerCap } from "../character/helper";

async function gameItemToChain(
    storageUnit: string,
    characterId: string,
    ownerCapId: string,
    playerAddress: string,
    typeId: bigint,
    itemId: bigint,
    volume: bigint,
    quantity: number,
    adminAddress: string,
    client: SuiClient,
    playerKeypair: Ed25519Keypair,
    adminKeypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Move Items from from game to Chain ====");

    const tx = new Transaction();
    tx.setSender(playerAddress);
    tx.setGasOwner(adminAddress);

    const [ownerCap, receipt] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.CHARACTER}::Character`],
        arguments: [tx.object(characterId), tx.object(ownerCapId)],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::game_item_to_chain_inventory`,
        typeArguments: [`${config.packageId}::${MODULES.CHARACTER}::Character`],
        arguments: [
            tx.object(storageUnit),
            tx.object(config.adminAcl),
            tx.object(characterId),
            ownerCap,
            tx.pure.u64(itemId),
            tx.pure.u64(typeId),
            tx.pure.u64(volume),
            tx.pure.u32(quantity),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::return_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.CHARACTER}::Character`],
        arguments: [tx.object(characterId), ownerCap, receipt],
    });

    const result = await executeSponsoredTransaction(
        tx,
        client,
        playerKeypair,
        adminKeypair,
        playerAddress,
        adminAddress,
        { showEvents: true }
    );

    console.log("Transaction digest:", result.digest);
    console.log("Item Id:", itemId);
}

async function main() {
    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.adminExportedKey);
        await hydrateWorldConfig(ctx);
        const playerKey = requireEnv("PLAYER_B_PRIVATE_KEY");
        const playerCtx = initializeContext(env.network, playerKey);
        shareHydratedConfig(ctx, playerCtx);
        const { client, keypair, config } = ctx;

        const playerAddress = playerCtx.address;
        const adminAddress = keypair.getPublicKey().toSuiAddress();

        const characterObject = deriveObjectId(
            config.objectRegistry,
            GAME_CHARACTER_B_ID,
            config.packageId
        );

        const storageUnit = deriveObjectId(
            config.objectRegistry,
            STORAGE_A_ITEM_ID,
            config.packageId
        );

        // Ephemeral inventory is owned by the character
        const characterOwnerCap = await getCharacterOwnerCap(
            characterObject,
            client,
            config,
            playerAddress
        );
        if (!characterOwnerCap) {
            throw new Error(`OwnerCap not found for ${characterObject}`);
        }

        await gameItemToChain(
            storageUnit,
            characterObject,
            characterOwnerCap,
            playerAddress,
            ITEM_A_TYPE_ID,
            ITEM_A_ITEM_ID,
            10n,
            10,
            adminAddress,
            client,
            playerCtx.keypair,
            keypair,
            config
        );
    } catch (error) {
        handleError(error);
    }
}

main();
