import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES, Network } from "../utils/config";
import { createClient, keypairFromPrivateKey } from "../utils/client";
import { deriveObjectId } from "../utils/derive-object-id";
import { CLOCK_OBJECT_ID, NWN_ITEM_ID } from "../utils/constants";
import { getOwnerCap } from "./helper";

const FUEL_TYPE_ID = 78437n;
const FUEL_QUANTITY = 2n;
const VOLUME = 10;

async function depositFuel(
    networkNodeId: string,
    ownerCapId: string,
    typeId: bigint,
    quantity: bigint,
    playerAddress: string,
    adminAddress: string,
    client: SuiClient,
    playerKeypair: Ed25519Keypair,
    adminKeypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log("\n==== Depositing Fuel to Network Node ====");

    const tx = new Transaction();
    tx.setSender(playerAddress);
    tx.setGasOwner(adminAddress);

    tx.moveCall({
        target: `${config.packageId}::${MODULES.NETWORK_NODE}::deposit_fuel`,
        arguments: [
            tx.object(networkNodeId),
            tx.object(config.adminAcl),
            tx.object(ownerCapId),
            tx.pure.u64(typeId),
            tx.pure.u64(VOLUME),
            tx.pure.u64(quantity),
            tx.object(CLOCK_OBJECT_ID),
        ],
    });

    const transactionKindBytes = await tx.build({ client, onlyTransactionKind: true });
    const gasCoins = await client.getCoins({
        owner: adminAddress,
        coinType: "0x2::sui::SUI",
        limit: 1,
    });

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
        options: { showObjectChanges: true, showEffects: true },
    });

    console.log("\n Fuel deposited successfully!");
    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    try {
        const network = (process.env.SUI_NETWORK as Network) || "localnet";
        const exportedKey = process.env.PRIVATE_KEY;
        const playerExportedKey = process.env.PLAYER_A_PRIVATE_KEY || exportedKey;

        if (!exportedKey || !playerExportedKey) {
            throw new Error(
                "PRIVATE_KEY and PLAYER_A_PRIVATE_KEY environment variables are required eg: PRIVATE_KEY=suiprivkey1..."
            );
        }

        const client = createClient(network);
        const adminKeypair = keypairFromPrivateKey(exportedKey);
        const playerKeypair = keypairFromPrivateKey(playerExportedKey);
        const config = getConfig(network);
        const playerAddress = playerKeypair.getPublicKey().toSuiAddress();
        const adminAddress = adminKeypair.getPublicKey().toSuiAddress();

        let networkNodeObject = deriveObjectId(
            config.objectRegistry,
            NWN_ITEM_ID,
            config.packageId
        );
        let networkNodeOwnerCap = await getOwnerCap(
            networkNodeObject,
            client,
            config,
            playerAddress
        );
        if (!networkNodeOwnerCap) {
            throw new Error(`OwnerCap not found for network node ${networkNodeObject}`);
        }

        await depositFuel(
            networkNodeObject,
            networkNodeOwnerCap,
            FUEL_TYPE_ID,
            FUEL_QUANTITY,
            playerAddress,
            adminAddress,
            client,
            playerKeypair,
            adminKeypair,
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
