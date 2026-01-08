import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, keypairFromPrivateKey } from "../utils/client";

const CLOCK_OBJECT_ID = "0x6";

const NETWORK_NODE_OBJECT_ID = "0x24e93560b47cd5e8fa8ea532859bc415fa7426f9b5267c8623dacec67d56e175";
const OWNER_CAP_OBJECT_ID = "0x62deeaf9f6fce5e2b115aa054e6f0a7087cc0bf641dd4a61545ce087e1c1ffab";
const FUEL_TYPE_ID = 8461n;
const FUEL_VOLUME = 1n;
const FUEL_QUANTITY = 2n;

async function depositFuel(
    networkNodeId: string,
    ownerCapId: string,
    typeId: bigint,
    volume: bigint,
    quantity: bigint,
    client: SuiClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Depositing Fuel to Network Node ====");

    const tx = new Transaction();

    tx.moveCall({
        target: `${config.packageId}::${MODULES.NETWORK_NODE}::deposit_fuel`,
        arguments: [
            tx.object(networkNodeId),
            tx.object(ownerCapId),
            tx.pure.u64(typeId),
            tx.pure.u64(volume),
            tx.pure.u64(quantity),
            tx.object(CLOCK_OBJECT_ID),
        ],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true },
    });

    console.log("\n Fuel deposited successfully!");
    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    console.log("============= Deposit Fuel example ==============\n");

    try {
        const network = (process.env.SUI_NETWORK as Network) || "localnet";
        const exportedKey = process.env.PLAYER_A_PRIVATE_KEY || process.env.PRIVATE_KEY;

        if (!exportedKey) {
            throw new Error(
                "PLAYER_A_PRIVATE_KEY or PRIVATE_KEY environment variable is required eg: PRIVATE_KEY=suiprivkey1..."
            );
        }

        const client = createClient(network);
        const keypair = keypairFromPrivateKey(exportedKey);
        const config = getConfig(network);
        const playerAddress = keypair.getPublicKey().toSuiAddress();

        await depositFuel(
            NETWORK_NODE_OBJECT_ID,
            OWNER_CAP_OBJECT_ID,
            FUEL_TYPE_ID,
            FUEL_VOLUME,
            FUEL_QUANTITY,
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
