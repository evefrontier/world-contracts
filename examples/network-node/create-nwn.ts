import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, keypairFromPrivateKey } from "../utils/client";
import { hexToBytes } from "../utils/helper";

const NWN_TYPE_ID = BigInt(Math.floor(Math.random() * 1000000) + 5);
const NWN_ITEM_ID = BigInt(Math.floor(Math.random() * 7) + 7);
const FUEL_MAX_CAPACITY = 10000n;
const FUEL_BURN_RATE_IN_MS = BigInt(3600 * 1000); // 1 hour
const MAX_ENERGY_PRODUCTION = 100n;
const LOCATION_HASH = "0x16217de8ec7330ec3eac32831df5c9cd9b21a255756a5fd5762dd7f49f6cc049";
const CHARACTER_OBJECT_ID = "0x50186a768934da5d173112e202d7d40a474a91aec2df7a724cfd073715afe13a";

async function createNetworkNode(
    characterObjectId: string,
    typeId: bigint,
    itemId: bigint,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    const tx = new Transaction();

    const [nwn] = tx.moveCall({
        target: `${config.packageId}::${MODULES.NETWORK_NODE}::anchor`,
        arguments: [
            tx.object(config.networkNodeRegistry),
            tx.object(characterObjectId),
            tx.object(config.adminCapObjectId),
            tx.pure.u64(itemId),
            tx.pure.u64(typeId),
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(LOCATION_HASH))),
            tx.pure.u64(FUEL_MAX_CAPACITY),
            tx.pure.u64(FUEL_BURN_RATE_IN_MS),
            tx.pure.u64(MAX_ENERGY_PRODUCTION),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.NETWORK_NODE}::share_network_node`,
        arguments: [nwn, tx.object(config.adminCapObjectId)],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showEvents: true },
    });

    console.log(result);

    const networkNodeEvent = result.events?.find((event) =>
        event.type.endsWith("::network_node::NetworkNodeCreatedEvent")
    );

    if (!networkNodeEvent?.parsedJson) {
        throw new Error("NetworkNodeCreatedEvent not found in transaction result");
    }

    const nwnId = (networkNodeEvent.parsedJson as { network_node_id: string }).network_node_id;
    console.log("NWN Object Id: ", nwnId);

    const ownerCapObjectId = (networkNodeEvent.parsedJson as { owner_cap_id: string }).owner_cap_id;
    console.log("OwnerCap Object Id: ", ownerCapObjectId);
}

async function main() {
    console.log("============= Create Network Node example ==============\n");

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

        await createNetworkNode(
            CHARACTER_OBJECT_ID,
            NWN_TYPE_ID,
            NWN_ITEM_ID,
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
