/// Killmail tracking system for EVE Frontier kills.
/// Emits killmail events for indexer-based queries.
/// Killmails are immutable records of player-vs-player combat losses.

module world::killmail;

use sui::{derived_object, event};
use world::{
    access::AdminACL,
    character::Character,
    in_game_id::{Self, TenantItemId},
    killmail_registry::KillmailRegistry
};

// === Errors ===
#[error(code = 0)]
const EKillmailIdEmpty: vector<u8> = b"Killmail ID cannot be empty";

#[error(code = 1)]
const ECharacterIdEmpty: vector<u8> = b"Character ID cannot be empty";

#[error(code = 2)]
const ESolarSystemIdEmpty: vector<u8> = b"Solar system ID cannot be empty";

#[error(code = 3)]
const EInvalidLossType: vector<u8> = b"Invalid loss type";

#[error(code = 4)]
const EInvalidTimestamp: vector<u8> = b"Invalid timestamp";

#[error(code = 5)]
const EKillmailAlreadyExists: vector<u8> = b"Killmail with this ItemId already exists";

// === Enums ===
/// Represents the type of loss in a killmail
public enum LossType has copy, drop, store {
    SHIP,
    STRUCTURE,
}

// === Structs ===
/// Represents a killmail as a shared object on the Sui blockchain
/// Can be queried directly using its Sui object ID
public struct Killmail has key {
    id: UID,
    key: TenantItemId,
    killer_id: TenantItemId,
    victim_id: TenantItemId,
    reported_by_character_id: TenantItemId,
    kill_timestamp: u64, // Unix timestamp in seconds
    loss_type: LossType,
    solar_system_id: TenantItemId,
}

// === Events ===
/// Emitted when a new killmail is created
public struct KillmailCreatedEvent has copy, drop {
    key: TenantItemId,
    killer_id: TenantItemId,
    victim_id: TenantItemId,
    reported_by_character_id: TenantItemId,
    loss_type: LossType,
    kill_timestamp: u64, // Unix timestamp in seconds
    solar_system_id: TenantItemId,
}

// === Public Functions ===
/// Returns the SHIP variant of LossType
public fun ship(): LossType {
    LossType::SHIP
}

/// Returns the STRUCTURE variant of LossType
public fun structure(): LossType {
    LossType::STRUCTURE
}

// === Admin Functions ===
/// Creates a new killmail as a shared object on-chain
/// Only authorized admin can create killmails
public fun create_killmail(
    registry: &mut KillmailRegistry,
    admin_acl: &AdminACL,
    item_id: u64,
    killer_id: u64,
    victim_id: u64,
    reported_by_character: &Character,
    kill_timestamp: u64,
    loss_type: u8,
    solar_system_id: u64,
    ctx: &mut TxContext,
) {
    admin_acl.verify_sponsor(ctx);

    let tenant = reported_by_character.tenant();
    // key to derive assembly object id
    let killmail_key = in_game_id::create_key(item_id, tenant);
    assert!(!registry.object_exists(killmail_key), EKillmailAlreadyExists);

    // Extract TenantItemId from characters
    let reported_by_character_id = reported_by_character.key();

    // Validate inputs
    assert!(item_id != 0, EKillmailIdEmpty);
    assert!(killer_id != 0, ECharacterIdEmpty);
    assert!(victim_id != 0, ECharacterIdEmpty);
    assert!(reported_by_character_id.item_id() != 0, ECharacterIdEmpty);

    assert!(solar_system_id != 0, ESolarSystemIdEmpty);
    assert!(kill_timestamp > 0, EInvalidTimestamp);

    // Create TenantItemId for killmail_id and solar_system_id
    let killmail_uid = derived_object::claim(registry.borrow_registry_id(), killmail_key);

    let killer_id = in_game_id::create_key(killer_id, tenant);
    let victim_id = in_game_id::create_key(victim_id, tenant);

    let solar_system_key = in_game_id::create_key(solar_system_id, tenant);

    // Convert u8 to LossType enum
    let loss_type_enum = loss_type_from_u8(loss_type);

    // Create the killmail as a shared object on-chain
    let killmail = Killmail {
        id: killmail_uid,
        key: killmail_key,
        killer_id,
        victim_id,
        reported_by_character_id,
        kill_timestamp,
        loss_type: loss_type_enum,
        solar_system_id: solar_system_key,
    };

    event::emit(KillmailCreatedEvent {
        key: killmail.key,
        killer_id: killmail.killer_id,
        victim_id: killmail.victim_id,
        reported_by_character_id: killmail.reported_by_character_id,
        loss_type: killmail.loss_type,
        kill_timestamp: killmail.kill_timestamp,
        solar_system_id: killmail.solar_system_id,
    });
    transfer::share_object(killmail);
}

/// Converts proto LossType u8 to LossType enum (1=SHIP, 2=STRUCTURE).
/// Aborts with EInvalidLossType for LOSS_UNSPECIFIED (0) or unknown values.
fun loss_type_from_u8(loss_type: u8): LossType {
    assert!(loss_type == 1 || loss_type == 2, EInvalidLossType);
    if (loss_type == 1) {
        LossType::SHIP
    } else {
        LossType::STRUCTURE
    }
}
