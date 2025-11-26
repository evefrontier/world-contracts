import "dotenv/config";
import { bcs } from "@mysten/sui/bcs";
import { signPersonalMessage } from "../crypto/signMessage";
import { toHex, fromHex } from "../utils/helper";
import { keypairFromPrivateKey } from "../utils/client";

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

// Test values from test_helpers.move
const SERVER_ADMIN_ADDRESS = "0x93d3209c7f138aded41dcb008d066ae872ed558bd8dcb562da47d4ef78295333";
const USER_A_ADDRESS = "0x202d7d52ab5f8e8824e3e8066c0b7458f84e326c5d77b30254c69d807586a7b0";
const STORAGE_UNIT_ID = "0xb78f2c84dbb71520c4698c4520bfca8da88ea8419b03d472561428cd1e3544e8";
const CHARACTER_ID = "0x0000000000000000000000000000000000000000000000000000000000000002";
const LOCATION_HASH = "0x16217de8ec7330ec3eac32831df5c9cd9b21a255756a5fd5762dd7f49f6cc049";
const TIMESTAMP_MS = 1763408644339n;

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

async function generateTestSignature() {
    console.log("=== Generating Test Signature for Move Tests ===\n");

    const privateKey = process.env.PRIVATE_KEY;

    if (!privateKey) {
        throw new Error("PRIVATE_KEY environment variable is required");
    }

    const keypair = keypairFromPrivateKey(privateKey);

    const derivedAddress = keypair.getPublicKey().toSuiAddress();
    console.log("Derived address:", derivedAddress);
    console.log("Expected address:", SERVER_ADMIN_ADDRESS);

    if (derivedAddress !== SERVER_ADMIN_ADDRESS) {
        console.warn("Make sure your PRIVATE_KEY corresponds to", SERVER_ADMIN_ADDRESS);
    }

    // Create the LocationProofMessage
    const message = {
        server_address: SERVER_ADMIN_ADDRESS,
        player_address: USER_A_ADDRESS,
        source_structure_id: CHARACTER_ID,
        source_location_hash: Array.from(fromHex(LOCATION_HASH)),
        target_structure_id: STORAGE_UNIT_ID,
        target_location_hash: Array.from(fromHex(LOCATION_HASH)),
        distance: 0n,
        data: [],
        deadline_ms: TIMESTAMP_MS,
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

generateTestSignature().catch((error) => {
    console.error("\n=== Error ===");
    console.error(error);
    process.exit(1);
});
