/// Unified registry to derive all in-game object ids for game assets
///
/// All game assets (characters, assemblies, network nodes, etc) derive their deterministic object IDs
/// from this single registry using TenantItemId (item_id + tenant) as the derivation key. This
/// guarantees that each in-game item ID can only be used once across all object types.
module world::object_registry;

use sui::derived_object;
use world::in_game_id::TenantItemId;

// === Structs ===
public struct ObjectRegistry has key {
    id: UID,
}

// === View Functions ===
public fun object_exists(registry: &ObjectRegistry, key: TenantItemId): bool {
    derived_object::exists(&registry.id, key)
}

// === Package Functions ===
public(package) fun borrow_registry_id(registry: &mut ObjectRegistry): &mut UID {
    &mut registry.id
}

// === Private Functions ===
fun init(ctx: &mut TxContext) {
    transfer::share_object(ObjectRegistry {
        id: object::new(ctx),
    });
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
