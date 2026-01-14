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
    PROOF,
} from "../utils/constants";
import { getOwnerCap } from "./helper";
import { deriveObjectId } from "../utils/derive-object-id";
import { initializeContext, handleError, getEnvConfig } from "../utils/helper";

async function chainItemToGame(
    storageUnit: string,
    characterId: string,
    ownerCapObjectId: string,
    typeId: bigint,
    quantity: number,
    client: SuiClient,
    playerKeypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Move Items from Chain to Game ====");

    const tx = new Transaction();

    tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::chain_item_to_game_inventory`,
        typeArguments: [`${config.packageId}::${MODULES.STORAGE_UNIT}::StorageUnit`],
        arguments: [
            tx.object(storageUnit),
            tx.object(config.serverAddressRegistry),
            tx.object(ownerCapObjectId),
            tx.object(characterId),
            tx.pure.u64(typeId),
            tx.pure.u32(quantity),
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(PROOF))),
            tx.object(CLOCK_OBJECT_ID),
        ],
    });

    const inspectResult = await client.devInspectTransactionBlock({
        transactionBlock: tx,
        sender: playerKeypair.getPublicKey().toSuiAddress(),
    });

    console.log(inspectResult);

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: playerKeypair,
        options: { showEvents: true },
    });
    console.log(result);

    const burnedEvent = result.events?.find((event) =>
        event.type.endsWith("::inventory::ItemBurnedEvent")
    );

    console.log("burnedEvent:", burnedEvent);
}

async function main() {
    try {
        const env = getEnvConfig();
        const playerCtx = initializeContext(env.network, env.playerExportedKey!);
        const { client, keypair, config } = playerCtx;

        let characterObject = deriveObjectId(
            config.objectRegistry,
            GAME_CHARACTER_ID,
            config.packageId
        );

        let storageUnit = deriveObjectId(
            config.objectRegistry,
            STORAGE_A_ITEM_ID,
            config.packageId
        );

        let storageUnitOwnerCap = await getOwnerCap(storageUnit, client, config, env.playerAddress);
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

main().catch(console.error);
