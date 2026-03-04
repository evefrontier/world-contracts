/// Killmail tracking system for EVE Frontier kills.
/// Emits killmail events for indexer-based queries.
/// Killmails are immutable records of player-vs-player combat losses.

module world::killmail;

use sui::event;
use world::{access::AdminACL, character::{Self, Character}, in_game_id::{Self, TenantItemId}};

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
const ETenantMismatch: vector<u8> = b"Killer and victim must have the same tenant";

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
    admin_acl: &AdminACL,
    killmail_item_id: u64,
    killer_character: &Character,
    victim_character: &Character,
    kill_timestamp: u64,
    loss_type: u8,
    solar_system_id: u64,
    ctx: &mut TxContext,
) {
    admin_acl.verify_sponsor(ctx);

    // Extract TenantItemId from characters
    let killer_character_id = character::key(killer_character);
    let victim_character_id = character::key(victim_character);

    let killer_tenant = character::tenant(killer_character);
    let victim_tenant = character::tenant(victim_character);

    // Assert that killer and victim have the same tenant
    assert!(killer_tenant == victim_tenant, ETenantMismatch);

    // Validate inputs
    assert!(killmail_item_id != 0, EKillmailIdEmpty);
    assert!(in_game_id::item_id(&killer_character_id) != 0, ECharacterIdEmpty);
    assert!(in_game_id::item_id(&victim_character_id) != 0, ECharacterIdEmpty);
    assert!(solar_system_id != 0, ESolarSystemIdEmpty);
    assert!(kill_timestamp > 0, EInvalidTimestamp);

    // Create TenantItemId for killmail_id and solar_system_id
    let killmail_id = in_game_id::create_key(killmail_item_id, killer_tenant);
    let solar_system_id_key = in_game_id::create_key(solar_system_id, killer_tenant);

    // Convert u8 to LossType enum
    let loss_type_enum = loss_type_from_u8(loss_type);

    // Create the killmail as a shared object on-chain
    let killmail = Killmail {
        id: object::new(ctx),
        killmail_id,
        killer_character_id,
        victim_character_id,
        kill_timestamp,
        loss_type: loss_type_enum,
        solar_system_id: solar_system_id_key,
    };

    // Share the object so it can be accessed by anyone on-chain
    transfer::share_object(killmail);

    // Emit event for indexer
    event::emit(KillmailCreatedEvent {
        killmail_id,
        killer_character_id,
        victim_character_id,
        solar_system_id: solar_system_id_key,
        loss_type: loss_type_enum,
        kill_timestamp,
    });
}

// === Private Functions ===
/// Converts u8 to LossType enum (0=SHIP, 1=STRUCTURE).
/// Aborts with EInvalidLossType if loss_type is not 0 or 1.
fun loss_type_from_u8(loss_type: u8): LossType {
    assert!(loss_type <= 1, EInvalidLossType);
    if (loss_type == 0) {
        LossType::SHIP
    } else {
        LossType::STRUCTURE
    }
}
