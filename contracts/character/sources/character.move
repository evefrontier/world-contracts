/// A Character is a `core::entity::Entity` carrying the `identity` module
///
/// The character object ID is derived from `(in_game_id, tenant)` via the
/// `ObjectRegistry`, so clients resolve it directly. Created with an empty
/// `location_hash` (a character is a principal, not a spatial structure).
module character::character;

use character::identity;
use core::{entity, object_registry::ObjectRegistry};
use std::string::String;
use sui::event;

// === Events ===

public struct CharacterCreated has copy, drop {
    character_id: ID,
    in_game_id: u64,
    tenant: String,
    tribe_id: u32,
    owner: address,
}

// === Public Functions ===

/// Character creation: installs identity and shares the entity.
/// TODO: gate creation behind an adminACL authorization requirement
public fun create(
    registry: &mut ObjectRegistry,
    in_game_id: u64,
    tenant: String,
    tribe_id: u32,
    owner: address,
    ctx: &mut TxContext,
) {
    let mut character = entity::new(registry, in_game_id, tenant, vector[]);
    let character_id = character.id();

    let req = identity::install(&mut character, tribe_id, owner, ctx);
    character.complete_request(req);

    character.share();

    event::emit(CharacterCreated { character_id, in_game_id, tenant, tribe_id, owner });
}
