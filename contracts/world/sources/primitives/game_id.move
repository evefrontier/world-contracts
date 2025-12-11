/// This module holds all the identifiers used in-game to refer to entities
module world::game_id;

use std::string::String;

// === Structs ===
/// Represents a unique in-game identifier used to deterministically derive on-chain object IDs.
public struct TenantItemDrvKey has copy, drop, store {
    item_id: u64,
    tenant: String,
}

// === View Functions ===
public fun item_id(key: &TenantItemDrvKey): u64 {
    key.item_id
}

public fun tenant(key: &TenantItemDrvKey): String {
    key.tenant
}

public(package) fun create_key(item_id: u64, tenant: String): TenantItemDrvKey {
    TenantItemDrvKey { item_id, tenant }
}
