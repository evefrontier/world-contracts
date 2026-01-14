import "dotenv/config";
import { bcs } from "@mysten/sui/bcs";
import { signPersonalMessage } from "../crypto/signMessage";
import { toHex, fromHex } from "../utils/helper";
import { keypairFromPrivateKey } from "../utils/client";
import { LOCATION_HASH, GAME_CHARACTER_ID, STORAGE_A_ITEM_ID } from "../utils/constants";
import { deriveObjectId } from "../utils/derive-object-id";
import { initializeContext, handleError, getEnvConfig } from "../utils/helper";

/**
 * This script generates test signatures for location proof verification in Move tests.
 *
 * The generated signature is used in:
 * - contracts/world/tests/test_helpers.move::construct_location_proof()
 *
 * To regenerate the signature:
 * 1. Set PRIVATE_KEY env var (must correspond to SERVER_ADMIN_ADDRESS)
 * 2. Run: npm run generate-test-signature
 * 3. Copy the "Full signature (hex)" output
 * 4. Update the signature in test_helpers.move::construct_location_proof()
 */
// BCS schema for LocationProofMessage (must match Move struct exactly)
const LocationProofMessage = bcs.struct("LocationProofMessage", {
    server_address: bcs.Address,
    player_address: bcs.Address,
    source_structure_id: bcs.Address,
    source_location_hash: bcs.vector(bcs.u8()),
    target_structure_id: bcs.Address,
    target_location_hash: bcs.vector(bcs.u8()),
    distance: bcs.u64(),
    data: bcs.vector(bcs.u8()),
    deadline_ms: bcs.u64(),
});

async function generateTestSignature(
    adminAddress: string,
    playerAddress: string,
    characterId: string,
    targetStructureId: string
) {
    console.log("=== Generating Test Signature for Move Tests ===\n");

    const privateKey = process.env.PRIVATE_KEY;

    if (!privateKey) {
        throw new Error("PRIVATE_KEY environment variable is required");
    }

    const keypair = keypairFromPrivateKey(privateKey);

    // Current unix time in ms + 5 days
    const deadline = BigInt(Date.now()) + BigInt(5 * 24 * 60 * 60 * 1000);

    // Create the LocationProofMessage
    const message = {
        server_address: adminAddress,
        player_address: playerAddress,
        source_structure_id: characterId,
        source_location_hash: Array.from(fromHex(LOCATION_HASH)),
        target_structure_id: targetStructureId,
        target_location_hash: Array.from(fromHex(LOCATION_HASH)),
        distance: 0n,
        data: [],
        deadline_ms: deadline,
    };

    console.log("\n=== Message Details ===");
    console.log("Server address:", message.server_address);
    console.log("Player address:", message.player_address);
    console.log("Source structure ID:", message.source_structure_id);
    console.log("Source location hash:", toHex(new Uint8Array(message.source_location_hash)));
    console.log("Target structure ID:", message.target_structure_id);
    console.log("Target location hash:", toHex(new Uint8Array(message.target_location_hash)));
    console.log("Distance:", message.distance.toString());
    console.log("Data:", message.data);
    console.log("Timestamp :", message.deadline_ms.toString());

    // Serialize the message
    const messageBytes = LocationProofMessage.serialize(message).toBytes();
    console.log("Message bytes (hex):", toHex(messageBytes));
    console.log("Message bytes length:", messageBytes.length);

    // Sign the message
    const signature = await signPersonalMessage(messageBytes, keypair);
    console.log("\n=== Signature ===");
    console.log("Full signature (hex):", toHex(signature));
    console.log("Signature length:", signature.length);

    // Create the full proof bytes (message + signature as vector)
    const signatureVec = bcs.vector(bcs.u8()).serialize(Array.from(signature)).toBytes();
    const proofBytes = new Uint8Array(messageBytes.length + signatureVec.length);
    proofBytes.set(messageBytes, 0);
    proofBytes.set(signatureVec, messageBytes.length);

    console.log("\n=== Full Proof Bytes (for bytes-based verification) ===");
    console.log("Proof bytes (hex):", toHex(proofBytes));
    console.log("Proof bytes length:", proofBytes.length);

    // Break down the signature components for verification
    console.log("\n=== Signature Components ===");
    console.log("Flag:", toHex(signature.slice(0, 1)));
    console.log("Raw signature:", toHex(signature.slice(1, 65)));
    console.log("Public key:", toHex(signature.slice(65, 97)));
}

async function main() {
    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.exportedKey);
        const { keypair, config } = ctx;
        const adminAddress = keypair.getPublicKey().toSuiAddress();
        const playerAddress = env.playerAddress;

        if (!playerAddress) {
            throw new Error(`Player address empty`);
        }

        let characterId = deriveObjectId(
            config.objectRegistry,
            GAME_CHARACTER_ID,
            config.packageId
        );

        let targetStructureId = deriveObjectId(
            config.objectRegistry,
            STORAGE_A_ITEM_ID,
            config.packageId
        );

        await generateTestSignature(adminAddress, playerAddress, characterId, targetStructureId);
    } catch (error) {
        handleError(error);
    }
}

main().catch(console.error);
