/// Killmail tracking system for EVE Frontier kills.
/// Emits killmail events for indexer-based queries.
/// Killmails are immutable records of player-vs-player combat losses.

module world::killmail;

use sui::event;
use world::{access::AdminACL, in_game_id::{Self, TenantItemId}};

// === Errors ===
#[error(code = 0)]
const EKillmailIdEmpty: vector<u8> = b"Killmail ID cannot be empty";

#[error(code = 1)]
const ECharacterIdEmpty: vector<u8> = b"Character ID cannot be empty";

#[error(code = 3)]
const ESolarSystemIdEmpty: vector<u8> = b"Solar system ID cannot be empty";

#[error(code = 5)]
const EInvalidTimestamp: vector<u8> = b"Invalid timestamp";

// === Enums ===
/// Represents the type of loss in a killmail
public enum LossType has copy, drop, store {
    SHIP,
    STRUCTURE,
}

/// Returns the SHIP variant of LossType
public fun ship(): LossType {
    LossType::SHIP
}

/// Returns the STRUCTURE variant of LossType
public fun structure(): LossType {
    LossType::STRUCTURE
}

// === Structs ===
/// Represents a killmail as a shared object on the Sui blockchain
/// Can be queried directly using its Sui object ID
public struct Killmail has key {
    id: UID,
    killmail_id: TenantItemId,
    killer_character_id: TenantItemId,
    victim_character_id: TenantItemId,
    kill_timestamp: u64, // Unix timestamp in seconds
    loss_type: LossType,
    solar_system_id: TenantItemId,
}

// === Events ===
/// Emitted when a new killmail is created
public struct KillmailCreatedEvent has copy, drop {
    killmail_id: TenantItemId,
    killer_character_id: TenantItemId,
    victim_character_id: TenantItemId,
    solar_system_id: TenantItemId,
    loss_type: LossType,
    kill_timestamp: u64, // Unix timestamp in seconds
}

// === Admin Functions ===
/// Creates a new killmail as a shared object on-chain
/// Only authorized admin can create killmails
public fun create_killmail(
    admin_acl: &AdminACL,
    killmail_id: TenantItemId,
    killer_character_id: TenantItemId,
    victim_character_id: TenantItemId,
    kill_timestamp: u64,
    loss_type: LossType,
    solar_system_id: TenantItemId,
    ctx: &mut TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    // Validate inputs
    assert!(in_game_id::item_id(&killmail_id) != 0, EKillmailIdEmpty);
    assert!(in_game_id::item_id(&killer_character_id) != 0, ECharacterIdEmpty);
    assert!(in_game_id::item_id(&victim_character_id) != 0, ECharacterIdEmpty);
    assert!(in_game_id::item_id(&solar_system_id) != 0, ESolarSystemIdEmpty);
    assert!(kill_timestamp > 0, EInvalidTimestamp);

    // Create the killmail as a shared object on-chain
    let killmail = Killmail {
        id: object::new(ctx),
        killmail_id,
        killer_character_id,
        victim_character_id,
        kill_timestamp,
        loss_type,
        solar_system_id,
    };

    // Share the object so it can be accessed by anyone on-chain
    transfer::share_object(killmail);

    // Emit event for indexer
    event::emit(KillmailCreatedEvent {
        killmail_id,
        killer_character_id,
        victim_character_id,
        solar_system_id,
        loss_type,
        kill_timestamp,
    });
}
