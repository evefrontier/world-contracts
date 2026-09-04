/// A Refinery is a `core::entity::Entity` carrying the `recipe` module.
///
/// Modeled on `character::character`: the object ID is derived from
/// `(in_game_id, tenant)` via the `ObjectRegistry`, the `recipe` module is
/// installed at creation, and the `start_refine` / `claim` actions are exposed.
/// Unlike a character, a refinery is a spatial structure, so it is created with
/// a non-empty `location_hash` and its interactions are proximity-gated by
/// `core::location_service`.
module refinery::refinery;

use core::{entity::{Self, Entity}, object_registry::ObjectRegistry};
use refinery::recipe::{Self, Recipe};
use std::string::{Self, String};
use sui::event;

// === Events ===

public struct RefineryCreated has copy, drop {
    refinery_id: ID,
    in_game_id: u64,
    tenant: String,
}

// === Public Functions ===

/// Create a refinery: install the recipe module and expose the start/claim
/// actions, then share the entity.
///
/// TODO: gate creation behind an adminACL authorization requirement, mirroring
/// the same TODO on `core::entity::new` and `character::create`.
public fun create(
    registry: &mut ObjectRegistry,
    in_game_id: u64,
    tenant: String,
    location_hash: vector<u8>,
    recipe: Recipe,
    ctx: &mut TxContext,
) {
    let mut refinery = entity::new(registry, in_game_id, tenant, location_hash);
    let refinery_id = refinery.id();

    // Each lifecycle op locks the entity and returns a Request that must be
    // completed (which unlocks) before the next op.
    let req = recipe::install(&mut refinery, recipe, ctx);
    refinery.complete_request(req);

    let req = refinery.enable_action(string::utf8(b"start_refine"), recipe::start_action(), ctx);
    refinery.complete_request(req);

    let req = refinery.enable_action(string::utf8(b"claim"), recipe::claim_action(), ctx);
    refinery.complete_request(req);

    refinery.share();

    event::emit(RefineryCreated { refinery_id, in_game_id, tenant });
}

// === View Functions ===

public fun recipe_of(refinery: &Entity): Recipe {
    recipe::recipe(refinery)
}

public fun has_active_job(refinery: &Entity): bool {
    recipe::has_active_job(refinery)
}
