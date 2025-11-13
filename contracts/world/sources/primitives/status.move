/// This module manages the lifecycle of a assembly in the world.
///
/// Basic AssemblyStatus are: Anchor, Unanchor/Destroy, Online and Offline assembly.
/// AssemblyStatus is mutable by admin and the assembly owner using capabilities.

module world::status;

use sui::event;
use world::authority::{Self, OwnerCap, AdminCap};

// === Errors ===
#[error(code = 0)]
const EAssemblyInvalidStatus: vector<u8> = b"Assembly status is invalid";

#[error(code = 1)]
const EAssemblyNotAuthorized: vector<u8> = b"Assembly access not authorized";

// === Structs ===
// After "unanchor" or "destroy" the State will not be available as the object will have been deleted.
public enum Status has copy, drop, store {
    ANCHORED,
    ONLINE,
    DESTROYED,
}

public struct AssemblyStatus has store {
    assembly_id: ID, // mapping to the assembly object id
    status: Status,
    // TODO: add a reference to an energy source to check if it has enough energy to online
}

// === Events ===
public struct StatusChangedEvent has copy, drop {
    assembly_id: ID,
    status: Status,
}

// === View Functions ===
public fun get_status(assembly_status: &AssemblyStatus): Status {
    assembly_status.status
}

public fun get_assembly_id(assembly_status: &AssemblyStatus): ID {
    assembly_status.assembly_id
}

public fun is_online(assembly_status: &AssemblyStatus): bool {
    assembly_status.status == Status::ONLINE
}

// === Public Functions ===
/// Online an assembly
public fun online(assembly_status: &mut AssemblyStatus, owner_cap: &OwnerCap) {
    assert!(assembly_status.status == Status::ANCHORED, EAssemblyInvalidStatus);
    assert!(
        authority::is_authorized(owner_cap, assembly_status.assembly_id),
        EAssemblyNotAuthorized,
    );
    // TODO: Check if it has enough reserved energy to online, else revert
    assembly_status.status = Status::ONLINE;
    event::emit(StatusChangedEvent {
        assembly_id: assembly_status.assembly_id,
        status: assembly_status.status,
    });
}

// TODO: On offline, it should release the reserved energy. Can be done in 2 ways
// 1. a hot potato pattern to ensure its done in PTB. 2. Call a release energy function implemented in energy module
/// Offline an assembly
public fun offline(assembly_status: &mut AssemblyStatus, owner_cap: &OwnerCap) {
    assert!(assembly_status.status == Status::ONLINE, EAssemblyInvalidStatus);
    assert!(
        authority::is_authorized(owner_cap, assembly_status.assembly_id),
        EAssemblyNotAuthorized,
    );
    assembly_status.status = Status::ANCHORED;
    event::emit(StatusChangedEvent {
        assembly_id: assembly_status.assembly_id,
        status: assembly_status.status,
    });
}

// === Package Functions ===
/// Anchors an assmebly and returns an instance of the status
public(package) fun anchor(_: &AdminCap, assembly_id: ID): AssemblyStatus {
    let assembly_status = AssemblyStatus {
        assembly_id: assembly_id,
        status: Status::ANCHORED,
    };
    event::emit(StatusChangedEvent {
        assembly_id: assembly_id,
        status: assembly_status.status,
    });
    assembly_status
}

/// Unanchor/Delete an assembly
public(package) fun unanchor(assembly_status: AssemblyStatus, _: &AdminCap) {
    assert!(
        assembly_status.status == Status::ANCHORED || assembly_status.status == Status::ONLINE,
        EAssemblyInvalidStatus,
    );

    // This event is only for informing the indexers of the status change
    event::emit(StatusChangedEvent {
        assembly_id: assembly_status.assembly_id,
        status: Status::DESTROYED,
    });

    let AssemblyStatus { assembly_id: _, status: _ } = assembly_status;
}

// === Test Functions ===
#[test_only]
public fun status_to_u8(assembly_status: &AssemblyStatus): u8 {
    match (assembly_status.status) {
        Status::ANCHORED => 0,
        Status::ONLINE => 1,
        Status::DESTROYED => 2,
    }
}
