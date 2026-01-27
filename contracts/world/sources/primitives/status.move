/// This module manages the lifecycle of a assembly in the world.
///
/// Basic AssemblyStatus are: Anchor, Unanchor/Destroy, Online and Offline assembly.
/// AssemblyStatus is mutable by admin and the assembly owner using capabilities.

module world::status;

use sui::event;
use world::in_game_id::TenantItemId;

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
    status: Status,
}

// === Events ===
public struct StatusChangedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    status: Status,
    action: Action,
}

// === View Functions ===

public fun status(assembly_status: &AssemblyStatus): Status {
    assembly_status.status
}

public fun is_online(assembly_status: &AssemblyStatus): bool {
    assembly_status.status == Status::ONLINE
}

// === Package Functions ===
/// Anchors an assembly and returns an instance of the status
public(package) fun anchor(assembly_id: ID, assembly_key: TenantItemId): AssemblyStatus {
    let assembly_status = AssemblyStatus {
        status: Status::OFFLINE,
    };
    emit_status_changed(assembly_status.status, Action::ANCHORED, assembly_id, assembly_key);
    assembly_status
}

// TODO: discuss the definition of an assembly and decouple the deleting logic to a seperate function
/// Unanchor an assembly
public(package) fun unanchor(
    assembly_status: AssemblyStatus,
    assembly_id: ID,
    assembly_key: TenantItemId,
) {
    assert!(
        assembly_status.status == Status::OFFLINE || assembly_status.status == Status::ONLINE,
        EAssemblyInvalidStatus,
    );

    // This event is only for informing the indexers of the status change
    emit_status_changed(Status::NULL, Action::UNANCHORED, assembly_id, assembly_key);

    let AssemblyStatus { .. } = assembly_status;
}

/// Online an assembly
public(package) fun online(
    assembly_status: &mut AssemblyStatus,
    assembly_id: ID,
    assembly_key: TenantItemId,
) {
    assert!(assembly_status.status == Status::OFFLINE, EAssemblyInvalidStatus);

    assembly_status.status = Status::ONLINE;
    emit_status_changed(assembly_status.status, Action::ONLINE, assembly_id, assembly_key);
}

/// Offline an assembly
public(package) fun offline(
    assembly_status: &mut AssemblyStatus,
    assembly_id: ID,
    assembly_key: TenantItemId,
) {
    assert!(assembly_status.status == Status::ONLINE, EAssemblyInvalidStatus);

    assembly_status.status = Status::OFFLINE;
    emit_status_changed(assembly_status.status, Action::OFFLINE, assembly_id, assembly_key);
}

fun emit_status_changed(
    status: Status,
    action: Action,
    assembly_id: ID,
    assembly_key: TenantItemId,
) {
    event::emit(StatusChangedEvent {
        assembly_id,
        assembly_key,
        status,
        action,
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
