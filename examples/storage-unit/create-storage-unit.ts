import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, keypairFromPrivateKey } from "../utils/client";
import { hexToBytes } from "../utils/helper";

const STORAGE_A_TYPE_ID = BigInt(Math.floor(Math.random() * 1000000) + 5);
const STORAGE_A_ITEM_ID = BigInt(Math.floor(Math.random() * 7) + 7);
const MAX_CAPACITY = 1000000000000n;
const LOCATION_HASH = "0x16217de8ec7330ec3eac32831df5c9cd9b21a255756a5fd5762dd7f49f6cc049";
const CHARACTER_OBJECT_ID = "0xce85fa882b9457458462aef487afc1ef045729e533aa78ded7f0d585b0cef659";

async function createStorageUnit(
    characterObjectId: string,
    typeId: bigint,
    itemId: bigint,
    address: string,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    const tx = new Transaction();

    const [storageUnit] = tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::anchor`,
        arguments: [
            tx.object(config.assemblyRegistry),
            tx.object(characterObjectId),
            tx.object(config.adminCapObjectId),
            tx.pure.u64(itemId),
            tx.pure.u64(typeId),
            tx.pure.u64(MAX_CAPACITY),
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(LOCATION_HASH))),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::share_storage_unit`,
        arguments: [storageUnit, tx.object(config.adminCapObjectId)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true },
    });

    console.log(result);

    const storageUnitId = result.objectChanges?.find(
        (change) => change.type === "created"
    )?.objectId;

    if (!storageUnitId) {
        throw new Error("Failed to create storage unit: object ID not found in transaction result");
    } else {
        console.log("Storagef Unit Object Id: ", storageUnitId);
    }
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

        await createStorageUnit(
            CHARACTER_OBJECT_ID,
            STORAGE_A_TYPE_ID,
            STORAGE_A_ITEM_ID,
            adminAddress,
            client,
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
