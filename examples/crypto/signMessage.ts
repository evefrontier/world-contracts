import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { blake2b } from "@noble/hashes/blake2b";
import { bcs } from "@mysten/sui/bcs";

/**
 * Creates an intent message following Sui's PersonalMessage format
 */
export function createIntentMessage(message: Uint8Array): Uint8Array {
    // BCS serialize the message bytes
    // BCS encodes the vector<u8> with length prefix
    const bcsSerializedMessage = bcs.vector(bcs.u8()).serialize(message).toBytes();

    // Prepend intent bytes [0x03]
    // 0x03 = PersonalMessage intent in Sui protocol
    const intentBytes = new Uint8Array([3, 0, 0]);

    // Step 3: Concatenate intent + bcs_serialized_message
    const intentMessage = new Uint8Array(intentBytes.length + bcsSerializedMessage.length);
    intentMessage.set(intentBytes, 0);
    intentMessage.set(bcsSerializedMessage, intentBytes.length);

    return intentMessage;
}

/**
 * Hashes the intent message using blake2b256
 */
export function hashIntentMessage(intentMessage: Uint8Array): Uint8Array {
    return blake2b(intentMessage, { dkLen: 32 }); // 32 bytes = 256 bits
}

/**
 * Signs a personal message and returns the full signature
 * Format: [flag][signature][public_key]
 * - flag (1 byte): 0x00 for Ed25519
 * - signature (64 bytes): Ed25519 signature
 * - public_key (32 bytes): Ed25519 public key
 *
 * This matches the format expected by sig_verify.move lines 24-46
 */
export async function signPersonalMessage(
    message: Uint8Array,
    keypair: Ed25519Keypair
): Promise<Uint8Array> {
    // Step 1: Create intent message (BCS + intent prepending)
    const intentMessage = createIntentMessage(message);

    // Step 2: Hash the intent message with blake2b256
    const digest = hashIntentMessage(intentMessage);

    // Step 3: Sign the digest using Ed25519
    const signature = await keypair.sign(digest);

    // Step 4: Get the public key
    const publicKey = keypair.getPublicKey().toRawBytes();

    // Step 5: Format as [flag][signature][public_key]
    // Flag 0x00 indicates Ed25519
    const fullSignature = new Uint8Array(1 + signature.length + publicKey.length);
    fullSignature[0] = 0x00; // ED25519_FLAG
    fullSignature.set(signature, 1);
    fullSignature.set(publicKey, 1 + signature.length);

    return fullSignature;
}

/**
 * Helper to convert Uint8Array to hex string for display/debugging
 */
export function toHex(bytes: Uint8Array): string {
    return (
        "0x" +
        Array.from(bytes)
            .map((b) => b.toString(16).padStart(2, "0"))
            .join("")
    );
}
