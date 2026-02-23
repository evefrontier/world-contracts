import "dotenv/config";
import { bcs } from "@mysten/sui/bcs";
import { Transaction } from "@mysten/sui/transactions";
import { MODULES } from "../utils/config";
import { deriveObjectId } from "../utils/derive-object-id";
import {
    CLOCK_OBJECT_ID,
    GAME_CHARACTER_ID,
    GATE_ITEM_ID_1,
    GATE_ITEM_ID_2,
    LOCATION_HASH,
} from "../utils/constants";
import {
    getEnvConfig,
    handleError,
    hexToBytes,
    hydrateWorldConfig,
    initializeContext,
    shareHydratedConfig,
    requireEnv,
} from "../utils/helper";
import { getOwnerCap } from "./helper";
import { keypairFromPrivateKey } from "../utils/client";
import { generateLocationProof } from "../utils/proof";
import { executeSponsoredTransaction } from "../utils/transaction";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";

async function linkGates(
    ctx: ReturnType<typeof initializeContext>,
    adminKeypair: Ed25519Keypair,
    adminAddress: string,
    character: number,
    gateAItemId: bigint,
    gateBItemId: bigint,
    proofHex: string
) {
    const { client, keypair, config, address } = ctx;

    const characterId = deriveObjectId(config.objectRegistry, character, config.packageId);
    const gateAId = deriveObjectId(config.objectRegistry, gateAItemId, config.packageId);
    const gateBId = deriveObjectId(config.objectRegistry, gateBItemId, config.packageId);

    const gateConfigId = config.gateConfig;

    const gateAOwnerCapId = await getOwnerCap(gateAId, client, config, address);
    const gateBOwnerCapId = await getOwnerCap(gateBId, client, config, address);
    if (!gateAOwnerCapId || !gateBOwnerCapId) {
        throw new Error("Gate OwnerCaps not found (make sure the character owns both gates)");
    }

    const tx = new Transaction();
    tx.setSender(address);
    tx.setGasOwner(adminAddress);

    const [gateAOwnerCap, gateAReceipt] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.GATE}::Gate`],
        arguments: [tx.object(characterId), tx.object(gateAOwnerCapId)],
    });

    const [gateBOwnerCap, gateBReceipt] = tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::borrow_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.GATE}::Gate`],
        arguments: [tx.object(characterId), tx.object(gateBOwnerCapId)],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.GATE}::link_gates`,
        arguments: [
            tx.object(gateAId),
            tx.object(gateBId),
            tx.object(gateConfigId),
            tx.object(config.serverAddressRegistry),
            tx.object(config.adminAcl),
            gateAOwnerCap,
            gateBOwnerCap,
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(proofHex))),
            tx.object(CLOCK_OBJECT_ID),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::return_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.GATE}::Gate`],
        arguments: [tx.object(characterId), gateAOwnerCap, gateAReceipt],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.CHARACTER}::return_owner_cap`,
        typeArguments: [`${config.packageId}::${MODULES.GATE}::Gate`],
        arguments: [tx.object(characterId), gateBOwnerCap, gateBReceipt],
    });

    const result = await executeSponsoredTransaction(
        tx,
        client,
        keypair,
        adminKeypair,
        address,
        adminAddress,
        { showEffects: true, showObjectChanges: true, showEvents: true }
    );

    console.log("\nGates linked successfully!");
    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    try {
        const env = getEnvConfig();
        const adminCtx = initializeContext(env.network, env.adminExportedKey);
        await hydrateWorldConfig(adminCtx);
        const playerKey = requireEnv("PLAYER_A_PRIVATE_KEY");
        const playerCtx = initializeContext(env.network, playerKey);
        shareHydratedConfig(adminCtx, playerCtx);

        const adminKeypair = adminCtx.keypair;
        const adminAddress = adminKeypair.getPublicKey().toSuiAddress();

        const characterId = deriveObjectId(
            playerCtx.config.objectRegistry,
            GAME_CHARACTER_ID,
            playerCtx.config.packageId
        );
        const gateAId = deriveObjectId(
            playerCtx.config.objectRegistry,
            GATE_ITEM_ID_1,
            playerCtx.config.packageId
        );

        const proofHex = await generateLocationProof(
            adminKeypair,
            playerCtx.address,
            characterId,
            gateAId,
            LOCATION_HASH
        );

        await linkGates(
            playerCtx,
            adminKeypair,
            adminAddress,
            GAME_CHARACTER_ID,
            GATE_ITEM_ID_1,
            GATE_ITEM_ID_2,
            proofHex
        );
    } catch (error) {
        handleError(error);
    }
}

main();
