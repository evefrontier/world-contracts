/// Location verification module for validating proximity using signature verification.
///
/// This module provides location hash storage and validation functionality that can be
/// attached to any game structure (e.g., inventory, item, ship, etc.). It enables
/// proximity-based access control by verifying that a player is in proximity
/// to a structure before allowing interactions.
module world::location;

use sui::{bcs, clock::Clock};
use world::{access::{Self, AdminCap, ServerAddressRegistry}, sig_verify};

// === Errors ===
#[error(code = 0)]
const ENotInProximity: vector<u8> = b"Structures are not in proximity";
#[error(code = 1)]
const EInvalidHashLength: vector<u8> = b"Invalid length for SHA256";
#[error(code = 2)]
const EUnverifiedSender: vector<u8> = b"The proof was not signed for the sender";
#[error(code = 3)]
const EInvalidLocationHash: vector<u8> = b"Invalid location hash";
#[error(code = 4)]
const EUnauthorizedServer: vector<u8> = b"Message signed by unauthorized server";
#[error(code = 5)]
const ESignatureVerificationFailed: vector<u8> = b"Signature verification failed";
#[error(code = 6)]
const EDeadlineExpired: vector<u8> = b"Deadline has expired";
#[error(code = 7)]
const EInvalidDistance: vector<u8> = b"Invalid Distance";

// === Structs ===

/// Represents a location hash attached to a game structure.
/// The location_hash should be a Poseidon2 hash of the location coordinates.
/// See: https://docs.sui.io/references/framework/sui_sui/poseidon
public struct Location has store {
    location_hash: vector<u8>,
}

/// A signed message containing location proof information.
/// This message is signed by an authorized server to prove that a player
/// is within proximity of a target structure.
///
/// # Arguments
/// * `server_address` - The address of the server that signed the message
/// * `player_address` - The address of the player to whom the proof is issued
/// * `source_structure_id` - The ID of the structure initiating the interaction
/// * `source_location_hash` - The hash of the source structure's location. eg: ship/gate location
/// * `target_structure_id` - The ID of the structure the player wants to interact with
/// * `target_location_hash` - The hash of the target structure's location
/// * `distance` - The distance between player and target structure
/// * `data` - Additional data field
/// * `deadline_ms` - expiration timestamp in milliseconds
public struct LocationProofMessage has drop {
    server_address: address,
    player_address: address,
    source_structure_id: ID,
    source_location_hash: vector<u8>,
    target_structure_id: ID,
    target_location_hash: vector<u8>,
    distance: u64,
    data: vector<u8>,
    deadline_ms: u64,
}

/// A complete location proof containing the message and its signature.
public struct LocationProof has drop {
    message: LocationProofMessage,
    signature: vector<u8>,
}

// === Public Functions ===

public fun create_location_proof(
    server_address: address,
    player_address: address,
    source_structure_id: ID,
    source_location_hash: vector<u8>,
    target_structure_id: ID,
    target_location_hash: vector<u8>,
    distance: u64,
    data: vector<u8>,
    deadline_ms: u64,
    signature: vector<u8>,
): LocationProof {
    let message = LocationProofMessage {
        server_address,
        player_address,
        source_structure_id,
        source_location_hash,
        target_structure_id,
        target_location_hash,
        distance,
        data,
        deadline_ms,
    };

    LocationProof {
        message,
        signature,
    }
}

/// Verify that a server-signed proof attesting a player is near a structure
/// This function gets `proof` LocationProof as struct
public fun verify_proximity(
    location: &Location,
    proof: LocationProof,
    server_registry: &ServerAddressRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let LocationProof { message, signature } = proof;

    validate_proof_message(&message, location, server_registry, ctx.sender());

    let message_bytes = bcs::to_bytes(&message);
    assert!(is_deadline_valid(message.deadline_ms, clock), EDeadlineExpired);
    assert!(
        sig_verify::verify_signature(
            message_bytes,
            signature,
            message.server_address,
        ),
        ESignatureVerificationFailed,
    )
}

/// Verify that a server-signed proof attesting a player is in proximity the structure.
/// This function gets `proof_bytes` the LocationProof as bytes
public fun verify_proximity_proof_from_bytes(
    server_registry: &ServerAddressRegistry,
    location: &Location,
    proof_bytes: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (message, signature) = unpack_proof(proof_bytes);

    validate_proof_message(&message, location, server_registry, ctx.sender());

    let message_bytes = bcs::to_bytes(&message);
    assert!(is_deadline_valid(message.deadline_ms, clock), EDeadlineExpired);
    assert!(
        sig_verify::verify_signature(
            message_bytes,
            signature,
            message.server_address,
        ),
        ESignatureVerificationFailed,
    )
}

/// Verify that a server-signed proof attesting two structures are under a certain distance.
public fun verify_distance(
    location: &Location,
    server_registry: &ServerAddressRegistry,
    proof_bytes: vector<u8>,
    max_distance: u64,
    ctx: &mut TxContext,
) {
    let (message, signature) = unpack_proof(proof_bytes);

    validate_proof_message(&message, location, server_registry, ctx.sender());

    let message_bytes = bcs::to_bytes(&message);
    assert!(message.distance <= max_distance, EInvalidDistance);
    assert!(
        sig_verify::verify_signature(
            message_bytes,
            signature,
            message.server_address,
        ),
        ESignatureVerificationFailed,
    )
}

/// Verifies if two locations are in proximity based on their hashes.
///
/// It is used for ephemeral storage operations where both inventory are in the same location
public fun verify_same_location(location_a_hash: vector<u8>, location_b_hash: vector<u8>) {
    assert!(location_a_hash == location_b_hash, ENotInProximity);
}

// === View Functions ===

public fun hash(location: &Location): vector<u8> {
    location.location_hash
}

// === Admin Functions ===

public fun update(location: &mut Location, _: &AdminCap, location_hash: vector<u8>) {
    assert!(location_hash.length() == 32, EInvalidHashLength);
    location.location_hash = location_hash;
}

// === Package Functions ===

public(package) fun attach(location_hash: vector<u8>): Location {
    assert!(location_hash.length() == 32, EInvalidHashLength);
    Location {
        location_hash,
    }
}

public(package) fun remove(location: Location) {
    let Location { .. } = location;
}

// === Private Functions ===

/// Validates the location proof message against the provided location and context.
fun validate_proof_message(
    message: &LocationProofMessage,
    expected_location: &Location,
    server_registry: &ServerAddressRegistry,
    sender: address,
) {
    assert!(
        access::is_authorized_server_address(server_registry, message.server_address),
        EUnauthorizedServer,
    );
    assert!(message.player_address == sender, EUnverifiedSender);
    assert!(message.target_location_hash == expected_location.location_hash, EInvalidLocationHash);
}

/// Deserializes a LocationProof from bytes using BCS peel functions.
///
/// BCS serializes structs field-by-field, so we peel each field in order:
/// 1. LocationProofMessage fields (server_address, player_address, etc.)
/// 2. signature (vector<u8>)
fun unpack_proof(proof_bytes: vector<u8>): (LocationProofMessage, vector<u8>) {
    let mut bcs_data = bcs::new(proof_bytes);

    // Deserialize LocationProofMessage fields
    let server_address = bcs_data.peel_address();
    let player_address = bcs_data.peel_address();
    let source_structure_id = object::id_from_address(bcs_data.peel_address());
    let source_location_hash = bcs_data.peel_vec!(|bcs| bcs.peel_u8());
    let target_structure_id = object::id_from_address(bcs_data.peel_address());
    let target_location_hash = bcs_data.peel_vec!(|bcs| bcs.peel_u8());
    let distance = bcs_data.peel_u64();
    let data = bcs_data.peel_vec!(|bcs| bcs.peel_u8());
    let deadline_ms = bcs_data.peel_u64();

    // Deserialize signature
    let signature = bcs_data.peel_vec!(|bcs| bcs.peel_u8());

    let message = LocationProofMessage {
        server_address,
        player_address,
        source_structure_id,
        source_location_hash,
        target_structure_id,
        target_location_hash,
        distance,
        data,
        deadline_ms,
    };
    (message, signature)
}

fun is_deadline_valid(deadline_ms: u64, clock: &Clock): bool {
    let current_time_ms = clock.timestamp_ms();
    deadline_ms > current_time_ms
}

// === Test Functions ===

/// Verifies a location proof without deadline validation (test-only).
///
/// This function is provided for testing purposes because Move does not have
/// built-in signing functionality. Messages signed offline need to be hardcoded
/// in tests, which means deadlines will always expire unless we set a never-expiring
/// deadline. This function bypasses deadline validation for testing convenience.
#[test_only]
public fun verify_proximity_without_deadline(
    server_registry: &ServerAddressRegistry,
    location: &Location,
    proof: LocationProof,
    ctx: &mut TxContext,
): bool {
    let LocationProof { message, signature } = proof;

    validate_proof_message(&message, location, server_registry, ctx.sender());

    let message_bytes = bcs::to_bytes(&message);
    sig_verify::verify_signature(
        message_bytes,
        signature,
        message.server_address,
    )
}

#[test_only]
public fun verify_proximity_proof_from_bytes_without_deadline(
    server_registry: &ServerAddressRegistry,
    location: &Location,
    proof_bytes: vector<u8>,
    ctx: &mut TxContext,
) {
    let (message, signature) = unpack_proof(proof_bytes);
    validate_proof_message(&message, location, server_registry, ctx.sender());

    let message_bytes = bcs::to_bytes(&message);
    assert!(
        sig_verify::verify_signature(
            message_bytes,
            signature,
            message.server_address,
        ),
        ESignatureVerificationFailed,
    );
}
