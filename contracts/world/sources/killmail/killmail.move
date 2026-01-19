/// Killmail tracking system for EVE Frontier kills.
/// Emits killmail events for indexer-based queries.
/// Killmails are immutable records of player-vs-player combat losses.

module world::killmail;

use sui::event;
use world::access::AdminCap;

// === Errors ===
#[error(code = 0)]
const EKillmailIdEmpty: vector<u8> = b"Killmail ID cannot be empty";

#[error(code = 1)]
const ECharacterIdEmpty: vector<u8> = b"Character ID cannot be empty";

#[error(code = 3)]
const ESolarSystemIdEmpty: vector<u8> = b"Solar system ID cannot be empty";

#[error(code = 4)]
const EInvalidLossType: vector<u8> = b"Invalid loss type";

#[error(code = 5)]
const EInvalidTimestamp: vector<u8> = b"Invalid timestamp";

// === Structs ===
/// Represents a killmail as a shared object on the Sui blockchain
/// Can be queried directly using its Sui object ID
public struct Killmail has key {
    id: UID,
    killmail_id: u32,
    killer_id: u64,
    victim_id: u64,
    kill_timestamp: u64,
    loss_type: u8,  // 0=SHIP, 1=POD
    solar_system_id: u64,
}

// === Events ===
/// Emitted when a new killmail is created
public struct KillmailCreatedEvent has copy, drop {
    killmail_id: u32,
    killer_id: u64,
    victim_id: u64,
    solar_system_id: u64,
    loss_type: u8,
    timestamp: u64,
}


// === Admin Functions ===
/// Creates a new killmail as a shared object on-chain
/// Only authorized admin can create killmails
public fun create_killmail(
    _admin_cap: &AdminCap,
    killmail_id: u32,
    killer_id: u64,
    victim_id: u64,
    kill_timestamp: u64,
    loss_type: u8,
    solar_system_id: u64,
    ctx: &mut TxContext,
) {
    // Validate inputs
    assert!(killmail_id != 0, EKillmailIdEmpty);
    assert!(killer_id != 0, ECharacterIdEmpty);
    assert!(victim_id != 0, ECharacterIdEmpty);
    assert!(solar_system_id != 0, ESolarSystemIdEmpty);
    assert!(kill_timestamp > 0, EInvalidTimestamp);
    assert!(loss_type <= 1, EInvalidLossType); // 0=SHIP, 1=POD

    // Create the killmail as a shared object on-chain
    let killmail = Killmail {
        id: object::new(ctx),
        killmail_id,
        killer_id,
        victim_id,
        kill_timestamp,
        loss_type,
        solar_system_id,
    };

    // Share the object so it can be accessed by anyone on-chain
    transfer::share_object(killmail);

    // Emit event for indexer
    event::emit(KillmailCreatedEvent {
        killmail_id,
        killer_id,
        victim_id,
        solar_system_id,
        loss_type,
        timestamp: kill_timestamp,
    });
}