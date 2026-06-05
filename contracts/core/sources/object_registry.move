/// Unified registry for deterministic entity object IDs.
///
/// Every entity derives its object ID from this registry using an `EntityKey`
/// (`id + tenant`), guaranteeing each in-game ID maps to exactly one on-chain object.
module core::object_registry;

use core::entity_key::EntityKey;
use sui::derived_object;

// === Structs ===

public struct ObjectRegistry has key {
    id: UID,
}

// === Init ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(ObjectRegistry { id: object::new(ctx) });
}

// === View Functions ===

public fun id(registry: &ObjectRegistry): ID {
    object::id(registry)
}

public fun exists(registry: &ObjectRegistry, key: EntityKey): bool {
    derived_object::exists(&registry.id, key)
}

public fun derive_id(registry: &ObjectRegistry, key: EntityKey): address {
    derived_object::derive_address(object::id(registry), key)
}

// === Package Functions ===

public(package) fun borrow_id(registry: &mut ObjectRegistry): &mut UID {
    &mut registry.id
}

// === Test Helpers ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
