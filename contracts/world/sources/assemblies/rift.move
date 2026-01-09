/// This module implements the Rift assembly for crude matter mining.
///
/// A Rift represents a mineable resource deposit containing crude matter.
/// Rifts can be mined by CrudeLift assemblies, but only one CrudeLift can mine
/// a rift at a time. Rifts can collapse, making them unavailable for mining.
module world::rift;

// Note: Option is available by default, no explicit import needed
use sui::{clock::Clock, event};
use world::{
    access::AdminCap,
    location::{Self, Location}
};

// === Errors ===
#[error(code = 0)]
const ERiftAlreadyBeingMined: vector<u8> = b"Rift is already being mined";
#[error(code = 1)]
const ERiftCollapsed: vector<u8> = b"Rift has collapsed";
#[error(code = 2)]
const ERiftNotBeingMined: vector<u8> = b"Rift is not being mined";
#[error(code = 3)]
const EInsufficientCrude: vector<u8> = b"Insufficient crude matter in rift";
#[error(code = 4)]
const EInvalidCrudeAmount: vector<u8> = b"Invalid crude amount";

// === Structs ===

/// Represents a mineable crude matter deposit.
/// Rifts are shared objects that can be mined by CrudeLift assemblies.
public struct Rift has key {
    id: UID,
    /// Remaining crude matter in this rift
    crude_amount: u64,
    /// ID of the CrudeLift currently mining this rift (if any)
    mining_crude_lift_id: Option<ID>,
    /// Timestamp when the rift collapsed (if applicable)
    collapsed_at: Option<u64>,
    /// Location of the rift
    location: Location,
}

// === Events ===

public struct RiftCreatedEvent has copy, drop {
    rift_id: ID,
    initial_crude_amount: u64,
    location_hash: vector<u8>,
}

public struct RiftCollapsedEvent has copy, drop {
    rift_id: ID,
    collapse_timestamp: u64,
    remaining_crude: u64,
}

public struct RiftMiningStartedEvent has copy, drop {
    rift_id: ID,
    crude_lift_id: ID,
    crude_amount: u64,
}

public struct RiftMiningStoppedEvent has copy, drop {
    rift_id: ID,
    crude_lift_id: ID,
    remaining_crude: u64,
}

public struct CrudeRemovedEvent has copy, drop {
    rift_id: ID,
    amount_removed: u64,
    remaining_crude: u64,
}

// === Public Functions ===

// === View Functions ===

/// Returns the amount of crude matter remaining in the rift.
public fun crude_amount(rift: &Rift): u64 {
    rift.crude_amount
}

/// Returns whether the rift has collapsed.
public fun is_collapsed(rift: &Rift): bool {
    rift.collapsed_at.is_some()
}

/// Returns whether the rift is currently being mined.
public fun is_being_mined(rift: &Rift): bool {
    rift.mining_crude_lift_id.is_some()
}

/// Returns the ID of the CrudeLift currently mining this rift, if any.
public fun mining_crude_lift_id(rift: &Rift): Option<ID> {
    rift.mining_crude_lift_id
}

/// Returns the collapse timestamp of the rift, if collapsed.
public fun collapsed_at(rift: &Rift): Option<u64> {
    rift.collapsed_at
}

/// Returns the location hash of the rift.
public fun location_hash(rift: &Rift): vector<u8> {
    rift.location.hash()
}

// === Admin Functions ===

/// Creates and shares a new rift with the specified crude amount and location.
/// Admin-only function for creating new rifts in the world.
public fun create_and_share_rift(
    _: &AdminCap,
    crude_amount: u64,
    location_hash: vector<u8>,
    ctx: &mut TxContext,
) {
    assert!(crude_amount > 0, EInvalidCrudeAmount);

    let rift_uid = object::new(ctx);
    let rift_id = object::uid_to_inner(&rift_uid);

    let rift = Rift {
        id: rift_uid,
        crude_amount,
        mining_crude_lift_id: option::none(),
        collapsed_at: option::none(),
        location: location::attach(rift_id, location_hash),
    };

    event::emit(RiftCreatedEvent {
        rift_id,
        initial_crude_amount: crude_amount,
        location_hash,
    });

    transfer::share_object(rift);
}

/// Forces a rift to collapse at the current time.
/// This permanently makes the rift unavailable for mining.
public fun collapse_rift(rift: &mut Rift, clock: &Clock) {
    if (!rift.is_collapsed()) {
        let current_time = clock.timestamp_ms();
        rift.collapsed_at.fill(current_time);

        event::emit(RiftCollapsedEvent {
            rift_id: object::id(rift),
            collapse_timestamp: current_time,
            remaining_crude: rift.crude_amount,
        });
    }
}

// === Package Functions ===

/// Removes crude matter from the rift.
/// Used by CrudeLift during mining operations.
public(package) fun remove_crude(rift: &mut Rift, amount: u64): u64 {
    assert!(!rift.is_collapsed(), ERiftCollapsed);
    assert!(rift.crude_amount >= amount, EInsufficientCrude);

    let _old_amount = rift.crude_amount;
    rift.crude_amount = rift.crude_amount - amount;

    event::emit(CrudeRemovedEvent {
        rift_id: object::id(rift),
        amount_removed: amount,
        remaining_crude: rift.crude_amount,
    });

    amount
}

/// Sets the CrudeLift that is mining this rift.
/// Only one CrudeLift can mine a rift at a time.
public(package) fun start_mining(rift: &mut Rift, crude_lift_id: ID) {
    assert!(!rift.is_collapsed(), ERiftCollapsed);
    assert!(rift.mining_crude_lift_id.is_none(), ERiftAlreadyBeingMined);

    rift.mining_crude_lift_id.fill(crude_lift_id);

    event::emit(RiftMiningStartedEvent {
        rift_id: object::id(rift),
        crude_lift_id,
        crude_amount: rift.crude_amount,
    });
}

/// Stops mining this rift by the specified CrudeLift.
public(package) fun stop_mining(rift: &mut Rift, crude_lift_id: ID) {
    assert!(rift.mining_crude_lift_id.is_some(), ERiftNotBeingMined);
    assert!(*rift.mining_crude_lift_id.borrow() == crude_lift_id, ERiftNotBeingMined);

    rift.mining_crude_lift_id = option::none();

    event::emit(RiftMiningStoppedEvent {
        rift_id: object::id(rift),
        crude_lift_id,
        remaining_crude: rift.crude_amount,
    });
}

/// Checks if a CrudeLift can start mining this rift.
/// Returns true if the rift is available for mining.
public(package) fun can_start_mining(rift: &Rift): bool {
    !rift.is_collapsed() && rift.mining_crude_lift_id.is_none()
}

// === Init ===

fun init(_ctx: &mut TxContext) {
    // Rift assembly doesn't require shared object initialization
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

// === Test Functions ===

#[test_only]
public fun create_test_rift(
    admin_cap: &AdminCap,
    crude_amount: u64,
    location_hash: vector<u8>,
    ctx: &mut TxContext,
): Rift {
    assert!(crude_amount > 0, EInvalidCrudeAmount);

    let rift_uid = object::new(ctx);
    let rift_id = object::uid_to_inner(&rift_uid);

    let rift = Rift {
        id: rift_uid,
        crude_amount,
        mining_crude_lift_id: option::none(),
        collapsed_at: option::none(),
        location: location::attach(rift_id, location_hash),
    };

    rift
}

#[test_only]
public fun create_and_share_test_rift(
    admin_cap: &AdminCap,
    crude_amount: u64,
    location_hash: vector<u8>,
    ctx: &mut TxContext,
): ID {
    assert!(crude_amount > 0, EInvalidCrudeAmount);

    let rift_uid = object::new(ctx);
    let rift_id = object::uid_to_inner(&rift_uid);

    let rift = Rift {
        id: rift_uid,
        crude_amount,
        mining_crude_lift_id: option::none(),
        collapsed_at: option::none(),
        location: location::attach(rift_id, location_hash),
    };

    event::emit(RiftCreatedEvent {
        rift_id,
        initial_crude_amount: crude_amount,
        location_hash,
    });

    transfer::share_object(rift);
    rift_id
}

#[test_only]
public fun destroy_test_rift(rift: Rift) {
    let Rift { id, location, .. } = rift;
    location.remove();
    id.delete();
}
