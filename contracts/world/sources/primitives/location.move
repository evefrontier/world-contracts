/// This module stores the location hash for location validation
/// This can be attached to any strucutre in game. eg: inventory, item, ship etc
///
module world::location;

use world::authority::AdminCap;

#[error(code = 0)]
const ENotInProximity: vector<u8> = b"Structures are not in proximity";

public struct Location has store {
    structure_id: ID,
    location_hash: vector<u8>, //TODO: do a wrapper for custom hash for type safety later
}

// Accepts a pre computed hash to preserve privacy
public fun attach_location(_: &AdminCap, structure_id: ID, location_hash: vector<u8>): Location {
    Location {
        structure_id: structure_id,
        location_hash: location_hash,
    }
}

public fun update_location(location: &mut Location, _: &AdminCap, location_hash: vector<u8>) {
    location.location_hash = location_hash;
}

// TODO: Should we also add distance param ?
/// Verifies if the locations are in proximity
public fun verify_proximity(location_a: &Location, location_b: &Location, proof: vector<u8>) {
    assert!(in_proximity(location_a, location_b, proof), ENotInProximity);
}

public fun in_proximity(_: &Location, _: &Location, _: vector<u8>): bool {
    //TODO: verify the signature proof against a trusted server key
    true
}
