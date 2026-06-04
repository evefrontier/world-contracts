/// Proximity requirement injected by `entity::interact`.
///
/// An interaction may only proceed when the caller proves they are within range
/// of the entity. v1 uses an exact match between the supplied proof and the
/// entity's stored location hash; cryptographic proximity proofs are out of
/// scope for this module and will be layered on later.
module core::location_service;

use core::{request::Request, requirement::{Self, Requirement}};
use std::internal::Permit;
use sui::bcs;

// === Errors ===

const EProximityMismatch: u64 = 0;

// === Structs ===

/// Requirement marker; wraps the required location hash.
public struct Proximity(vector<u8>) has drop;

// === Public Functions ===

/// Build a proximity requirement for `location_hash`.
public fun proximity_requirement(location_hash: vector<u8>): Requirement {
    requirement::from_config(option::none(), Proximity(location_hash))
}

/// Satisfy the next (proximity) requirement on `request`. Aborts unless `proof`
/// matches the required location hash.
public fun verify_proximity(request: &mut Request, proof: vector<u8>) {
    // TODO: Replace hash equality with server-signed LocationProof verification
    // (authorized server registry, player == sender, target hash, deadline, sig_verify).
    let (requirement, frame) = request.take_next(permit());
    let required = bcs::new(requirement.data()).peel_vec_u8();
    assert!(proof == required, EProximityMismatch);
    frame.destroy_empty_frame();
}

// === Private Functions ===

/// Mint the package-authorship permit for `Proximity`. Only this module defines
/// `Proximity`, so only this module can satisfy its requirement.
fun permit(): Permit<Proximity> {
    internal::permit<Proximity>()
}
