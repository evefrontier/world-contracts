import { bcs } from "@mysten/sui/bcs";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { signPersonalMessage } from "../crypto/signMessage";
import { fromHex, toHex } from "./helper";

// BCS schema for LocationProofMessage (must match Move struct exactly)
export const LocationProofMessage = bcs.struct("LocationProofMessage", {
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

export interface LocationProofOptions {
    distance?: bigint;
    data?: number[];
    deadline_ms?: bigint;
}

/**
 * Generate a location proof signed by the admin keypair.
 * Returns the full proof bytes as a hex string (message + BCS-encoded signature).
 */
export async function generateLocationProof(
    adminKeypair: Ed25519Keypair,
    playerAddress: string,
    sourceStructureId: string,
    targetStructureId: string,
    locationHash: string,
    options?: LocationProofOptions
): Promise<string> {
    const adminAddress = adminKeypair.getPublicKey().toSuiAddress();
    const deadline = options?.deadline_ms ?? BigInt(Date.now()) + BigInt(50 * 24 * 60 * 60 * 1000);

    const message = {
        server_address: adminAddress,
        player_address: playerAddress,
        source_structure_id: sourceStructureId,
        source_location_hash: Array.from(fromHex(locationHash)),
        target_structure_id: targetStructureId,
        target_location_hash: Array.from(fromHex(locationHash)),
        distance: options?.distance ?? 0n,
        data: options?.data ?? [],
        deadline_ms: deadline,
    };

    const messageBytes = LocationProofMessage.serialize(message).toBytes();
    const signature = await signPersonalMessage(messageBytes, adminKeypair);

    // Combine message + BCS-encoded signature vector into full proof bytes
    const signatureVec = bcs.vector(bcs.u8()).serialize(Array.from(signature)).toBytes();
    const proofBytes = new Uint8Array(messageBytes.length + signatureVec.length);
    proofBytes.set(messageBytes, 0);
    proofBytes.set(signatureVec, messageBytes.length);

    return toHex(proofBytes);
}
