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

async function withdraw(
    storageUnit: string,
    characterId: string,
    ownerCapId: string,
    typeId: bigint,
    client: SuiClient,
    playerKeypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    const tx = new Transaction();

    const [ownerCap] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.STORAGE_UNIT}::StorageUnit`],
        arguments: [tx.object(characterId), tx.object(ownerCapId)],
    });

    const [item] = tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::withdraw_by_owner`,
        typeArguments: [`${config.packageId}::${MODULES.STORAGE_UNIT}::StorageUnit`],
        arguments: [
            tx.object(storageUnit),
            tx.object(config.serverAddressRegistry),
            tx.object(characterId),
            ownerCap,
            tx.pure.u64(typeId),
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(PROOF))),
            tx.object(CLOCK_OBJECT_ID),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::deposit_by_owner`,
        typeArguments: [`${config.packageId}::${MODULES.STORAGE_UNIT}::StorageUnit`],
        arguments: [
            tx.object(storageUnit),
            tx.object(item),
            tx.object(config.serverAddressRegistry),
            tx.object(characterId),
            ownerCap,
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(PROOF))),
            tx.object(CLOCK_OBJECT_ID),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::return_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.STORAGE_UNIT}::StorageUnit`],
        arguments: [tx.object(characterId), ownerCap],
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

    const withdrawEvent = result.events?.find((event) =>
        event.type.endsWith("::inventory::ItemWithdrawnEvent")
    );

    if (!withdrawEvent) {
        throw new Error("ItemWithdrawnEvent not found in transaction result");
    }

    console.log("withdrawEvent:", withdrawEvent);
}

async function main() {
    try {
        const env = getEnvConfig();
        const playerCtx = initializeContext(env.network, env.playerExportedKey!);
        const { client, keypair, config } = playerCtx;
        const playerAddress = playerCtx.address;

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

        let storageUnitOwnerCap = await getOwnerCap(storageUnit, client, config, playerAddress);
        if (!storageUnitOwnerCap) {
            throw new Error(`OwnerCap not found for ${storageUnit}`);
        }

        await withdraw(
            storageUnit,
            characterObject,
            storageUnitOwnerCap,
            ITEM_A_TYPE_ID,
            client,
            keypair,
            config
        );
    } catch (error) {
        handleError(error);
    }
}

main().catch(console.error);
