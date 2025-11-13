/// This module stores the location hash for location validation.
/// This can be attached to any structure in game, eg: inventory, item, ship etc.
module world::location;

use world::authority::AdminCap;

// === Errors ===
#[error(code = 0)]
const ENotInProximity: vector<u8> = b"Structures are not in proximity";
#[error(code = 1)]
const EInvalidHashLength: vector<u8> = b"Invalid length for SHA256";

// === Structs ===
public struct Location has store {
    structure_id: ID,
    location_hash: vector<u8>, //TODO: do a wrapper for custom hash for type safety later
}

// === Public Functions ===

// TODO: Should we also add distance param ?
/// Verifies if the locations are in proximity.
/// `proof` - Cryptographic proof of proximity. Currently: Signature from trusted server. Future: Zero-knowledge proof.
public fun verify_proximity(location_a: &Location, location_b: &Location, proof: vector<u8>) {
    assert!(
        in_proximity(location_a.location_hash, location_b.location_hash, proof),
        ENotInProximity,
    );
}

// === View Functions ===
public fun in_proximity(_: vector<u8>, _: vector<u8>, _: vector<u8>): bool {
    //TODO: check location_a and location_b is in same location
    //TODO: verify the signature proof against a trusted server key
    true
}

public fun get_hash(location: &Location): vector<u8> {
    location.location_hash
}

// === Admin Functions ===
public fun update_location(location: &mut Location, _: &AdminCap, location_hash: vector<u8>) {
    assert!(location_hash.length() == 32, EInvalidHashLength);
    location.location_hash = location_hash;
}

// === Package Functions ===
// Accepts a pre computed hash to preserve privacy
public(package) fun attach_location(
    _: &AdminCap,
    structure_id: ID,
    location_hash: vector<u8>,
): Location {
    assert!(location_hash.length() == 32, EInvalidHashLength);
    Location {
        structure_id: structure_id,
        location_hash: location_hash,
    }
}

public(package) fun remove_location(location: Location) {
    let Location { structure_id: _, location_hash: _ } = location;
}
