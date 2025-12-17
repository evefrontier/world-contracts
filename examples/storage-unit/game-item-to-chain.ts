import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, keypairFromPrivateKey } from "../utils/client";

const CHARACTER_OBJECT_ID = "0xce85fa882b9457458462aef487afc1ef045729e533aa78ded7f0d585b0cef659";
const STORAGE_UNIT = "0xf8be2f792c0940b318b63e12a221e201fef08f0ec6186177aded0c539851236d";
const STORAGE_OWNER_CAP = "0xaaf1e3b6701c80a4a95b96765e9a2b3181a6f7bb83678198e6abac808d56a6db";

const ITEM_A_TYPE_ID = BigInt(Math.floor(Math.random() * 1000) + 5);
const CORPSE_ITEM_ID = BigInt(Math.floor(Math.random() * 777000) + 8);

async function gameItemToChain(
    storageUnit: string,
    characterId: string,
    owner_cap_objectId: string,
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

    tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::game_item_to_chain_inventory`,
        typeArguments: [`${config.packageId}::${MODULES.STORAGE_UNIT}::StorageUnit`],
        arguments: [
            tx.object(storageUnit),
            tx.object(config.adminAclObjectId),
            tx.object(owner_cap_objectId),
            tx.object(characterId),
            tx.pure.u64(itemId),
            tx.pure.u64(typeId),
            tx.pure.u64(volume),
            tx.pure.u32(quantity),
        ],
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

    const mintEvent = result.events?.find((event) =>
        event.type.endsWith("::inventory::ItemMintedEvent")
    );

    if (!mintEvent) {
        throw new Error("ItemMintedEvent not found in transaction result");
    }

    const eventData = mintEvent.parsedJson as { item_uid: string };
    const itemObjectId = eventData.item_uid;

    if (!itemObjectId) {
        throw new Error("Failed to get item UID from ItemMintedEvent");
    }

    console.log("itemObjectId objectId:", itemObjectId);
}

async function main() {
    console.log("============= Create Storage Unit example ==============\n");

    try {
        const network = (process.env.SUI_NETWORK as Network) || "localnet";
        const exportedKey = process.env.PRIVATE_KEY;
        const playerExportedKey = process.env.PLAYER_A_PRIVATE_KEY || exportedKey;
        const tenant = process.env.TENANT || "";

        if (!exportedKey || !playerExportedKey) {
            throw new Error(
                "PRIVATE_KEY environment variable is required eg: PRIVATE_KEY=suiprivkey1..."
            );
        }

        const client = createClient(network);
        const keypair = keypairFromPrivateKey(exportedKey);
        const playerKeypair = keypairFromPrivateKey(playerExportedKey);
        const config = getConfig(network);

        const playerAddress = playerKeypair.getPublicKey().toSuiAddress();
        const adminAddress = keypair.getPublicKey().toSuiAddress();

        await gameItemToChain(
            STORAGE_UNIT,
            CHARACTER_OBJECT_ID,
            STORAGE_OWNER_CAP,
            playerAddress,
            ITEM_A_TYPE_ID,
            CORPSE_ITEM_ID,
            10n,
            10,
            adminAddress,
            client,
            playerKeypair,
            keypair,
            config
        );
    } catch (error) {
        console.error("\n=== Error ===");
        console.error("Error:", error instanceof Error ? error.message : error);
        if (error instanceof Error && error.stack) {
            console.error("Stack:", error.stack);
        }
        process.exit(1);
    }
}

main().catch(console.error);
