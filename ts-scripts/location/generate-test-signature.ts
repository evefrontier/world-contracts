import "dotenv/config";
import { keypairFromPrivateKey } from "../utils/client";
import { LOCATION_HASH, GAME_CHARACTER_ID, STORAGE_A_ITEM_ID } from "../utils/constants";
import { deriveObjectId } from "../utils/derive-object-id";
import {
    hydrateWorldConfig,
    initializeContext,
    handleError,
    getEnvConfig,
    requireEnv,
    hexToBytes,
} from "../utils/helper";
import { generateLocationProof } from "../utils/proof";

/**
 * This script generates test signatures for location proof verification in Move tests.
 *
 * The generated signature is used in:
 * - contracts/world/tests/test_helpers.move::construct_location_proof()
 *
 * To regenerate the signature:
 * 1. Set ADMIN_PRIVATE_KEY env var (must correspond to the server admin key used in tests)
 * 2. Run: pnpm run generate-test-sig
 * 3. Copy the "Full signature (hex)" output
 * 4. Update the signature in test_helpers.move::construct_location_proof()
 */

async function main() {
    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.adminExportedKey);
        await hydrateWorldConfig(ctx);
        const { config } = ctx;

        const adminKeypair = keypairFromPrivateKey(requireEnv("ADMIN_PRIVATE_KEY"));
        const adminAddress = adminKeypair.getPublicKey().toSuiAddress();
        const playerKey = requireEnv("PLAYER_A_PRIVATE_KEY");
        const playerAddress = keypairFromPrivateKey(playerKey).getPublicKey().toSuiAddress();

        const characterId = deriveObjectId(
            config.objectRegistry,
            GAME_CHARACTER_ID,
            config.packageId
        );

        const targetStructureId = deriveObjectId(
            config.objectRegistry,
            STORAGE_A_ITEM_ID,
            config.packageId
        );

        console.log("=== Generating Test Signature for Move Tests ===\n");
        console.log("Server address:", adminAddress);
        console.log("Player address:", playerAddress);
        console.log("Source structure ID (character):", characterId);
        console.log("Target structure ID:", targetStructureId);
        console.log("Location hash:", LOCATION_HASH);

        const proofHex = await generateLocationProof(
            adminKeypair,
            playerAddress,
            characterId,
            targetStructureId,
            LOCATION_HASH
        );

        console.log("\n=== Full Proof Bytes (for bytes-based verification) ===");
        console.log("Proof bytes (hex):", proofHex);
        console.log("Proof bytes length:", hexToBytes(proofHex).length);
    } catch (error) {
        handleError(error);
    }
}

main();
