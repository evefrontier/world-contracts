import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES } from "../utils/config";
import { hexToBytes } from "../utils/helper";
import {
    CLOCK_OBJECT_ID,
    GAME_CHARACTER_ID,
    STORAGE_A_ITEM_ID,
    ITEM_A_TYPE_ID,
    PLAYER_A_PROOF,
} from "../utils/constants";
import { getOwnerCap } from "./helper";
import { deriveObjectId } from "../utils/derive-object-id";
import {
    getEnvConfig,
    handleError,
    hydrateWorldConfig,
    initializeContext,
    requireEnv,
} from "../utils/helper";

async function chainItemToGame(
    storageUnit: string,
    characterId: string,
    ownerCapId: string,
    typeId: bigint,
    quantity: number,
    client: SuiClient,
    playerKeypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Move Items from Chain to Game ====");

    const tx = new Transaction();
    const [ownerCap] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.STORAGE_UNIT}::StorageUnit`],
        arguments: [tx.object(characterId), tx.object(ownerCapId)],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::chain_item_to_game_inventory`,
        typeArguments: [`${config.packageId}::${MODULES.STORAGE_UNIT}::StorageUnit`],
        arguments: [
            tx.object(storageUnit),
            tx.object(config.serverAddressRegistry),
            tx.object(characterId),
            ownerCap,
            tx.pure.u64(typeId),
            tx.pure.u32(quantity),
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(PLAYER_A_PROOF))),
            tx.object(CLOCK_OBJECT_ID),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::return_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.STORAGE_UNIT}::StorageUnit`],
        arguments: [tx.object(characterId), ownerCap],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: playerKeypair,
        options: { showEvents: true },
    });
    console.log("Transaction digest:", result.digest);

    const burnedEvent = result.events?.find((event) =>
        event.type.endsWith("::inventory::ItemBurnedEvent")
    );

    console.log("burnedEvent:", burnedEvent);
}

async function main() {
    try {
        const env = getEnvConfig();
        const playerKey = requireEnv("PLAYER_A_PRIVATE_KEY");
        const playerCtx = initializeContext(env.network, playerKey);
        await hydrateWorldConfig(playerCtx);
        const { client, keypair, config } = playerCtx;

        const characterObject = deriveObjectId(
            config.objectRegistry,
            GAME_CHARACTER_ID,
            config.packageId
        );

        const storageUnit = deriveObjectId(
            config.objectRegistry,
            STORAGE_A_ITEM_ID,
            config.packageId
        );

        const storageUnitOwnerCap = await getOwnerCap(
            storageUnit,
            client,
            config,
            playerCtx.address
        );
        if (!storageUnitOwnerCap) {
            throw new Error(`OwnerCap not found for ${storageUnit}`);
        }
        await chainItemToGame(
            storageUnit,
            characterObject,
            storageUnitOwnerCap,
            ITEM_A_TYPE_ID,
            10,
            client,
            keypair,
            config
        );
    } catch (error) {
        handleError(error);
    }
}

main();
