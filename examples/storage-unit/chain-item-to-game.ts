import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, keypairFromPrivateKey } from "../utils/client";
import { hexToBytes } from "../utils/helper";

const CLOCK_ID = "0x6";
const CHARACTER_OBJECT_ID = "0xd84a2c755b063e89799dadbfd769c3e49a4e41a4748b611d87a3bf0fa05271e8";
const STORAGE_UNIT = "0xa7597edbdac993411e11b9b867b7b9eddc395719d7512ef750afdc7cd109c723";
const STORAGE_OWNER_CAP = "0x6d1a27c2ab7693b26d4c6c19e6d080c44ddbfcd144d9d79bb86ac5c1f74a5a45";
const PROOF =
    "0x93d3209c7f138aded41dcb008d066ae872ed558bd8dcb562da47d4ef78295333202d7d52ab5f8e8824e3e8066c0b7458f84e326c5d77b30254c69d807586a7b0d84a2c755b063e89799dadbfd769c3e49a4e41a4748b611d87a3bf0fa05271e82016217de8ec7330ec3eac32831df5c9cd9b21a255756a5fd5762dd7f49f6cc049a7597edbdac993411e11b9b867b7b9eddc395719d7512ef750afdc7cd109c7232016217de8ec7330ec3eac32831df5c9cd9b21a255756a5fd5762dd7f49f6cc049000000000000000000e08fc2b79b010000610035e4e6d32bb9de00205de330c9b5e98603f30f412553ac6022d3d03b7e4fdb453c3ec5977a1b4b6996084847904f7486fc0c9900d27c42ca2f4df410d2c70808a94e21ea26cc336019c11a5e10c4b39160188dda0f6b4bfe198dd689db8f3df9";

const ITEM_ID = 69530n;

async function chainItemToGame(
    storageUnit: string,
    characterId: string,
    ownerCapObjectId: string,
    itemId: bigint,
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
            tx.pure.u64(itemId),
            tx.pure.u32(quantity),
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(PROOF))),
            tx.object(CLOCK_ID),
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
    console.log("============= Chain To Game example ==============\n");

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
        const playerKeypair = keypairFromPrivateKey(playerExportedKey);
        const config = getConfig(network);

        await chainItemToGame(
            STORAGE_UNIT,
            CHARACTER_OBJECT_ID,
            STORAGE_OWNER_CAP,
            ITEM_ID,
            10,
            client,
            playerKeypair,
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
