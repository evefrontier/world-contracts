/// Registry for deriving killmail object IDs.
/// Killmails use a dedicated registry so their IDs are independent of the main ObjectRegistry.

module world::killmail_registry;

use sui::derived_object;
use world::in_game_id::TenantItemId;

// === Structs ===
public struct KillmailRegistry has key {
    id: UID,
}

// === View Functions ===
public fun object_exists(registry: &KillmailRegistry, key: TenantItemId): bool {
    derived_object::exists(&registry.id, key)
}

// === Package Functions ===
public(package) fun borrow_registry_id(registry: &mut KillmailRegistry): &mut UID {
    &mut registry.id
}

// === Private Functions ===
fun init(ctx: &mut TxContext) {
    transfer::share_object(KillmailRegistry {
        id: object::new(ctx),
    });
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
