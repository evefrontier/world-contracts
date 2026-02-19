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
    LOCATION_HASH,
} from "../utils/constants";
import { getOwnerCap } from "./helper";
import { deriveObjectId } from "../utils/derive-object-id";
import {
    getEnvConfig,
    handleError,
    hydrateWorldConfig,
    initializeContext,
    shareHydratedConfig,
    requireEnv,
} from "../utils/helper";
import { keypairFromPrivateKey } from "../utils/client";
import { generateLocationProof } from "../utils/proof";
import { executeSponsoredTransaction } from "../utils/transaction";

async function withdraw(
    storageUnit: string,
    characterId: string,
    ownerCapId: string,
    typeId: bigint,
    proofHex: string,
    playerAddress: string,
    adminAddress: string,
    client: SuiClient,
    playerKeypair: Ed25519Keypair,
    adminKeypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    const tx = new Transaction();
    tx.setSender(playerAddress);
    tx.setGasOwner(adminAddress);

    const [ownerCap, receipt] = tx.moveCall({
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
            tx.object(config.adminAcl),
            ownerCap,
            tx.pure.u64(typeId),
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(proofHex))),
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
            tx.object(config.adminAcl),
            ownerCap,
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(proofHex))),
            tx.object(CLOCK_OBJECT_ID),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::return_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.STORAGE_UNIT}::StorageUnit`],
        arguments: [tx.object(characterId), ownerCap, receipt],
    });

    const result = await executeSponsoredTransaction(
        tx,
        client,
        playerKeypair,
        adminKeypair,
        playerAddress,
        adminAddress,
        { showEvents: true },
    );
    console.log("Transaction digest:", result.digest);

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
        const adminCtx = initializeContext(env.network, env.adminExportedKey);
        await hydrateWorldConfig(adminCtx);
        const playerKey = requireEnv("PLAYER_A_PRIVATE_KEY");
        const playerCtx = initializeContext(env.network, playerKey);
        shareHydratedConfig(adminCtx, playerCtx);
        const { client, keypair: adminKeypair, config } = adminCtx;

        const playerAddress = playerCtx.address;
        const adminAddress = adminKeypair.getPublicKey().toSuiAddress();

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

        const storageUnitOwnerCap = await getOwnerCap(storageUnit, client, config, playerAddress);
        if (!storageUnitOwnerCap) {
            throw new Error(`OwnerCap not found for ${storageUnit}`);
        }

        const proofHex = await generateLocationProof(
            adminKeypair,
            playerAddress,
            characterObject,
            storageUnit,
            LOCATION_HASH
        );

        await withdraw(
            storageUnit,
            characterObject,
            storageUnitOwnerCap,
            ITEM_A_TYPE_ID,
            proofHex,
            playerAddress,
            adminAddress,
            client,
            playerCtx.keypair,
            adminKeypair,
            config
        );
    } catch (error) {
        handleError(error);
    }
}

main();
