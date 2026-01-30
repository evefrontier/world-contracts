import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES } from "../utils/config";
import { deriveObjectId } from "../utils/derive-object-id";
import { initializeContext, handleError, getEnvConfig } from "../utils/helper";
import {
    GAME_CHARACTER_ID,
    STORAGE_A_ITEM_ID,
    ITEM_A_TYPE_ID,
    ITEM_A_ITEM_ID,
} from "../utils/constants";
import { getOwnerCap } from "./helper";

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

    const [ownerCap] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.STORAGE_UNIT}::StorageUnit`],
        arguments: [tx.object(characterId), tx.object(ownerCapId)],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::game_item_to_chain_inventory`,
        typeArguments: [`${config.packageId}::${MODULES.STORAGE_UNIT}::StorageUnit`],
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
        typeArguments: [`${config.packageId}::${MODULES.STORAGE_UNIT}::StorageUnit`],
        arguments: [tx.object(characterId), ownerCap],
    });

    const transactionKindBytes = await tx.build({ client, onlyTransactionKind: true });
    const gasCoins = await client.getCoins({
        owner: adminAddress,
        coinType: "0x2::sui::SUI",
        limit: 1,
    });

    if (gasCoins.data.length === 0) {
        throw new Error("Admin has no gas coins to sponsor the transaction");
    }

    const gasPayment = gasCoins.data.map((coin) => ({
        objectId: coin.coinObjectId,
        version: coin.version,
        digest: coin.digest,
    }));

    // Reconstruct transaction with gas payment
    const sponsoredTx = Transaction.fromKind(transactionKindBytes);
    sponsoredTx.setSender(playerAddress);
    sponsoredTx.setGasOwner(adminAddress);
    sponsoredTx.setGasPayment(gasPayment);
    const transactionBytes = await sponsoredTx.build({ client });

    const playerSignature = await playerKeypair.signTransaction(transactionBytes);
    const adminSignature = await adminKeypair.signTransaction(transactionBytes);

    // Execute with both signatures
    const result = await client.executeTransactionBlock({
        transactionBlock: transactionBytes,
        signature: [playerSignature.signature, adminSignature.signature],
        options: { showEvents: true },
    });

    console.log(result);

    console.log("Item Id:", itemId);
}

async function main() {
    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.exportedKey);
        const playerCtx = initializeContext(env.network, env.playerExportedKey!);
        const { client, keypair, config } = ctx;

        const playerAddress = playerCtx.address;
        const adminAddress = keypair.getPublicKey().toSuiAddress();

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

        await gameItemToChain(
            storageUnit,
            characterObject,
            storageUnitOwnerCap,
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

main().catch(console.error);
