/// In-game identifier used to deterministically derive on-chain object IDs.
///
/// `id` is drawn from a single global ID space (assumption : item ids and type ids never overlap),
/// so one key type covers both singleton and non-singleton entities.
module core::entity_key;

use std::string::String;

// === Structs ===

public struct EntityKey has copy, drop, store {
    id: u64, // could be type_id or item_id
    tenant: String,
}

// === Public Functions ===

public fun new(id: u64, tenant: String): EntityKey {
    EntityKey { id, tenant }
}

// === View Functions ===

public fun id(key: &EntityKey): u64 {
    key.id
}

public fun tenant(key: &EntityKey): String {
    key.tenant
}
