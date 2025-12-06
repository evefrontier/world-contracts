/// This module defines the key type used to derive object IDs in world contracts
/// using game ID and tenant.
module world::game_id;

use std::string::String;

// === Structs ===
public struct GameId has copy, drop, store {
    id: u64,
    tenant: String,
}

// === View Functions ===
public fun id(game_id: &GameId): u64 {
    game_id.id
}

public fun tenant(game_id: &GameId): String {
    game_id.tenant
}

public(package) fun create_key(id: u64, tenant: String): GameId {
    GameId { id, tenant }
}
