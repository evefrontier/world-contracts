import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, keypairFromPrivateKey } from "../utils/client";
import { hexToBytes } from "../utils/helper";

const ASSEMBLY_TYPE_ID = 55557n;
const ASSEMBLY_ITEM_ID = BigInt(Math.floor(Math.random() * 7) + 7);
const VOLUME = 10;
const LOCATION_HASH = "0x16217de8ec7330ec3eac32831df5c9cd9b21a255756a5fd5762dd7f49f6cc049";
const CHARACTER_OBJECT_ID = "0x50186a768934da5d173112e202d7d40a474a91aec2df7a724cfd073715afe13a";
const NETWORK_NODE_OBJECT_ID = "0x24e93560b47cd5e8fa8ea532859bc415fa7426f9b5267c8623dacec67d56e175";

async function createAssembly(
    characterObjectId: string,
    networkNodeObjectId: string,
    typeId: bigint,
    itemId: bigint,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    const tx = new Transaction();

    const [assembly] = tx.moveCall({
        target: `${config.packageId}::${MODULES.ASSEMBLY}::anchor`,
        arguments: [
            tx.object(config.assemblyRegistry),
            tx.object(networkNodeObjectId),
            tx.object(characterObjectId),
            tx.object(config.adminCapObjectId),
            tx.pure.u64(itemId),
            tx.pure.u64(typeId),
            tx.pure.u64(VOLUME),
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(LOCATION_HASH))),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.ASSEMBLY}::share_assembly`,
        arguments: [assembly, tx.object(config.adminCapObjectId)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEvents: true },
    });

    console.log(result);

    const assemblyEvent = result.events?.find((event) =>
        event.type.endsWith("::assembly::AssemblyCreatedEvent")
    );

    if (!assemblyEvent?.parsedJson) {
        throw new Error("AssemblyCreatedEvent not found in transaction result");
    }

    const assemblyId = (assemblyEvent.parsedJson as { assembly_id: string }).assembly_id;
    console.log("Assembly Object Id: ", assemblyId);

    const ownerCapObjectId = (assemblyEvent.parsedJson as { owner_cap_id: string }).owner_cap_id;
    console.log("OwnerCap Object Id: ", ownerCapObjectId);
}

async function main() {
    console.log("============= Create Assembly Unit example ==============\n");

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

        await createAssembly(
            CHARACTER_OBJECT_ID,
            NETWORK_NODE_OBJECT_ID,
            ASSEMBLY_TYPE_ID,
            ASSEMBLY_ITEM_ID,
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
