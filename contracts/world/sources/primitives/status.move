/// This module manages the lifecycle of a assembly in the world.
///
/// Basic AssemblyStatus are: Anchor, Unanchor/Destroy, Online and Offline assembly.
/// AssemblyStatus is mutable by admin and the assembly owner using capabilities.

module world::status;

use sui::event;

// === Errors ===
#[error(code = 0)]
const EAssemblyInvalidStatus: vector<u8> = b"Assembly status is invalid";

// === Structs ===
public enum Status has copy, drop, store {
    NULL,
    OFFLINE,
    ONLINE,
}

public enum Action has copy, drop, store {
    ANCHORED,
    ONLINE,
    OFFLINE,
    UNANCHORED,
}

public struct AssemblyStatus has store {
    assembly_id: ID, // mapping to the assembly object id
    status: Status,
    type_id: u64,
    item_id: u64,
}

// === Events ===
public struct StatusChangedEvent has copy, drop {
    assembly_id: ID,
    status: Status,
    item_id: u64,
    action: Action,
}

// === View Functions ===

public fun status(assembly_status: &AssemblyStatus): Status {
    assembly_status.status
}

public fun assembly_id(assembly_status: &AssemblyStatus): ID {
    assembly_status.assembly_id
}

public fun is_online(assembly_status: &AssemblyStatus): bool {
    assembly_status.status == Status::ONLINE
}

// === Package Functions ===
/// Anchors an assmebly and returns an instance of the status
public(package) fun anchor(assembly_id: ID, type_id: u64, item_id: u64): AssemblyStatus {
    let assembly_status = AssemblyStatus {
        assembly_id: assembly_id,
        status: Status::OFFLINE,
        type_id: type_id,
        item_id: item_id,
    };
    event::emit(StatusChangedEvent {
        assembly_id: assembly_id,
        status: assembly_status.status,
        item_id: assembly_status.item_id,
        action: Action::ANCHORED,
    });
    assembly_status
}

// TODO: discuss the definition of an assembly and decouple the deleting logic to a seperate function
/// Unanchor an assembly
public(package) fun unanchor(assembly_status: AssemblyStatus) {
    assert!(
        assembly_status.status == Status::OFFLINE || assembly_status.status == Status::ONLINE,
        EAssemblyInvalidStatus,
    );

    // This event is only for informing the indexers of the status change
    event::emit(StatusChangedEvent {
        assembly_id: assembly_status.assembly_id,
        item_id: assembly_status.item_id,
        status: Status::NULL,
        action: Action::UNANCHORED,
    });

    let AssemblyStatus { .. } = assembly_status;
}

/// Online an assembly
public(package) fun online(assembly_status: &mut AssemblyStatus) {
    assert!(assembly_status.status == Status::OFFLINE, EAssemblyInvalidStatus);

    // TODO: Check if it has enough reserved energy to online, else revert
    assembly_status.status = Status::ONLINE;
    event::emit(StatusChangedEvent {
        assembly_id: assembly_status.assembly_id,
        status: assembly_status.status,
        item_id: assembly_status.item_id,
        action: Action::ONLINE,
    });
}

// TODO: On offline, it should release the reserved energy. Can be done in 2 ways
// 1. a hot potato pattern to ensure its done in PTB. 2. Call a release energy function implemented in energy module
/// Offline an assembly
public(package) fun offline(assembly_status: &mut AssemblyStatus) {
    assert!(assembly_status.status == Status::ONLINE, EAssemblyInvalidStatus);

    assembly_status.status = Status::OFFLINE;
    event::emit(StatusChangedEvent {
        assembly_id: assembly_status.assembly_id,
        status: assembly_status.status,
        item_id: assembly_status.item_id,
        action: Action::OFFLINE,
    });
}

// === Test Functions ===
#[test_only]
public fun status_to_u8(assembly_status: &AssemblyStatus): u8 {
    match (assembly_status.status) {
        Status::NULL => 0,
        Status::ONLINE => 1,
        Status::OFFLINE => 2,
    }
}
