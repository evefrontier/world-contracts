import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { MODULES } from "../utils/config";
import { initializeContext, handleError, getEnvConfig } from "../utils/helper";
import { executeSponsoredTransaction } from "../utils/transaction";
import { deriveObjectId } from "../utils/derive-object-id";
import { CLOCK_OBJECT_ID, GAME_CHARACTER_ID, NWN_ITEM_ID } from "../utils/constants";
import { getOwnerCap } from "./helper";
import { keypairFromPrivateKey } from "../utils/client";

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
    playerCtx: ReturnType<typeof initializeContext>,
    adminKeypair: ReturnType<typeof keypairFromPrivateKey>
) {
    console.log("\n==== Depositing Fuel to Network Node ====");

    const { client, keypair: playerKeypair, config } = playerCtx;

    const tx = new Transaction();
    tx.setSender(playerAddress);
    tx.setGasOwner(adminAddress);

    const character = deriveObjectId(config.objectRegistry, GAME_CHARACTER_ID, config.packageId);
    tx.moveCall({
        target: `${config.packageId}::${MODULES.NETWORK_NODE}::deposit_fuel`,
        arguments: [
            tx.object(networkNodeId),
            tx.object(config.adminAcl),
            tx.object(character),
            tx.object(ownerCapId),
            tx.pure.u64(typeId),
            tx.pure.u64(VOLUME),
            tx.pure.u64(quantity),
            tx.object(CLOCK_OBJECT_ID),
        ],
    });

    const result = await executeSponsoredTransaction(
        tx,
        client,
        playerKeypair,
        adminKeypair,
        playerAddress,
        adminAddress
    );

    console.log("\n Fuel deposited successfully!");
    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    try {
        const env = getEnvConfig();
        const playerCtx = initializeContext(env.network, env.playerExportedKey!);
        const adminKeypair = keypairFromPrivateKey(env.exportedKey);
        const playerAddress = playerCtx.address;
        const adminAddress = adminKeypair.getPublicKey().toSuiAddress();
        const config = playerCtx.config;

        let networkNodeObject = deriveObjectId(
            config.objectRegistry,
            NWN_ITEM_ID,
            config.packageId
        );
        let networkNodeOwnerCap = await getOwnerCap(
            networkNodeObject,
            playerCtx.client,
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
            playerCtx,
            adminKeypair
        );
    } catch (error) {
        handleError(error);
    }
}

main().catch(console.error);
