import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES } from "../utils/config";
import { hexToBytes, getAdminCapId } from "../utils/helper";
import { initializeContext, handleError, getEnvConfig } from "../utils/helper";
import {
    LOCATION_HASH,
    GAME_CHARACTER_ID,
    NWN_ITEM_ID,
    STORAGE_A_TYPE_ID,
    STORAGE_A_ITEM_ID,
} from "../utils/constants";
import { deriveObjectId } from "../utils/derive-object-id";

const MAX_CAPACITY = 1000000000000n;

async function createStorageUnit(
    characterObjectId: string,
    networkNodeObjectId: string,
    typeId: bigint,
    itemId: bigint,
    adminCap: string,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    const tx = new Transaction();

    const [storageUnit] = tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::anchor`,
        arguments: [
            tx.object(config.objectRegistry),
            tx.object(networkNodeObjectId),
            tx.object(characterObjectId),
            tx.object(adminCap!),
            tx.pure.u64(itemId),
            tx.pure.u64(typeId),
            tx.pure.u64(MAX_CAPACITY),
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(LOCATION_HASH))),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::share_storage_unit`,
        arguments: [storageUnit, tx.object(adminCap)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEvents: true },
    });

    console.log(result);

    const storageUnitEvent = result.events?.find((event) =>
        event.type.endsWith("::storage_unit::StorageUnitCreatedEvent")
    );

    if (!storageUnitEvent?.parsedJson) {
        throw new Error("StorageUnitCreatedEvent not found in transaction result");
    }

    const storageUnitId = (storageUnitEvent.parsedJson as { storage_unit_id: string })
        .storage_unit_id;
    console.log("Storage Unit Object Id: ", storageUnitId);

    const ownerCapObjectId = (storageUnitEvent.parsedJson as { owner_cap_id: string }).owner_cap_id;
    console.log("OwnerCap Object Id: ", ownerCapObjectId);
}

async function main() {
    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.exportedKey);
        const { client, keypair, config } = ctx;
        const adminCap = await getAdminCapId(client, config.packageId);

        let characterObject = deriveObjectId(
            config.objectRegistry,
            GAME_CHARACTER_ID,
            config.packageId
        );
        let networkNodeObject = deriveObjectId(
            config.objectRegistry,
            NWN_ITEM_ID,
            config.packageId
        );

        await createStorageUnit(
            characterObject,
            networkNodeObject,
            STORAGE_A_TYPE_ID,
            STORAGE_A_ITEM_ID,
            adminCap!,
            client,
            keypair,
            config
        );
    } catch (error) {
        handleError(error);
    }
}

main().catch(console.error);
