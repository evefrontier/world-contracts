/// Proximity requirement injected by `entity::interact`.
///
/// An interaction may only proceed when the caller proves they are within range
/// of the target. v1 uses an exact match between `caller_location_hash` (player,
/// or the ship/structure they are boarded on) and the `target_location_hash`
/// baked into the requirement at interact; cryptographic proximity proofs are
/// out of scope for this module and will be layered on later.
module core::location_service;

use core::{request::Request, requirement::{Self, Requirement}};
use std::internal::Permit;
use sui::bcs;

// === Errors ===

#[error(code = 0)]
const EProximityMismatch: vector<u8> = b"Caller location does not match the target";

// === Structs ===

/// Requirement marker; wraps the target location hash.
public struct Proximity(vector<u8>) has drop;

// === Public Functions ===

/// Build a proximity requirement for `target_location_hash`.
public fun proximity_requirement(target_location_hash: vector<u8>): Requirement {
    requirement::from_config(option::none(), Proximity(target_location_hash))
}

/// Satisfy the next (proximity) requirement on `request`. Aborts unless
/// `caller_location_hash` matches the target location hash.
public fun verify_proximity(request: &mut Request, caller_location_hash: vector<u8>) {
    // TODO: Replace hash equality with server-signed LocationProof verification
    // (authorized server registry, player == sender, target hash, deadline, sig_verify).
    let (requirement, frame) = request.take_next(permit());
    let required = bcs::new(requirement.data()).peel_vec_u8();
    assert!(caller_location_hash == required, EProximityMismatch);
    frame.destroy_empty_frame();
}

// === Private Functions ===

/// Mint the package-authorship permit for `Proximity`. Only this module defines
/// `Proximity`, so only this module can satisfy its requirement.
fun permit(): Permit<Proximity> {
    internal::permit<Proximity>()
}
