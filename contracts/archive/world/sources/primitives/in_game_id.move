/// This module holds all the identifiers used in-game to refer to entities
module world::in_game_id;

use std::string::String;

// === Structs ===
/// Represents a unique in-game identifier used to deterministically derive on-chain object IDs.
/// # Argument
/// * `item_id`- The unique in-game item identifier
/// * `tenant` - Different game server instances e.g. production/development/testing”
public struct TenantItemId has copy, drop, store {
    item_id: u64,
    tenant: String,
}

// === View Functions ===
public fun item_id(key: &TenantItemId): u64 {
    key.item_id
}

public fun tenant(key: &TenantItemId): String {
    key.tenant
}

public(package) fun create_key(item_id: u64, tenant: String): TenantItemId {
    TenantItemId { item_id, tenant }
}
