/// This module handles all the operations for generalized assemblies
/// Basic operations are anchor, unanchor, online, offline and destroy
module world::assembly;

use sui::{derived_object, event};
use world::{
    authority::{Self, AdminCap, OwnerCap},
    location::{Self, Location},
    metadata::Metadata,
    status::{Self, AssemblyStatus}
};

// === Errors ===
#[error(code = 0)]
const EAssemblyTypeIdEmpty: vector<u8> = b"Assembly TypeId is empty";
#[error(code = 1)]
const EAssemblyItemIdEmpty: vector<u8> = b"Assembly ItemId is empty";
#[error(code = 2)]
const EAssemblyAlreadyExists: vector<u8> = b"Assembly with this ItemId already exists";
#[error(code = 3)]
const EAssemblyNotAuthorized: vector<u8> = b"Assembly access not authorized";

// === Structs ===
public struct AssemblyRegistry has key {
    id: UID,
}

public struct Assembly has key {
    id: UID,
    type_id: u64,
    item_id: u64,
    volume: u64,
    status: AssemblyStatus,
    location: Location,
    metadata: Option<Metadata>,
}

// === Events ===
public struct AssemblyCreatedEvent has copy, drop {
    assembly_id: ID,
    type_id: u64,
    item_id: u64,
    volume: u64,
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(AssemblyRegistry {
        id: object::new(ctx),
    });
}

// === Public Functions ===
public fun online(assembly: &mut Assembly, owner_cap: &OwnerCap) {
    assert!(authority::is_authorized(owner_cap, object::id(assembly)), EAssemblyNotAuthorized);
    assembly.status.online();
}

public fun offline(assembly: &mut Assembly, owner_cap: &OwnerCap) {
    assert!(authority::is_authorized(owner_cap, object::id(assembly)), EAssemblyNotAuthorized);
    assembly.status.offline();
}

// === View Functions ===
public fun status(assembly: &Assembly): &AssemblyStatus {
    &assembly.status
}

// === Admin Functions ===
public fun anchor(
    assembly_registry: &mut AssemblyRegistry,
    _: &AdminCap,
    type_id: u64,
    item_id: u64,
    volume: u64,
    location_hash: vector<u8>,
    _: &mut TxContext,
): Assembly {
    assert!(type_id != 0, EAssemblyTypeIdEmpty);
    assert!(item_id != 0, EAssemblyItemIdEmpty);
    assert!(!assembly_exists(assembly_registry, item_id), EAssemblyAlreadyExists);

    let assembly_uid = derived_object::claim(&mut assembly_registry.id, item_id);
    let assembly_id = object::uid_to_inner(&assembly_uid);
    let assembly = Assembly {
        id: assembly_uid,
        type_id,
        item_id,
        volume,
        status: status::anchor(assembly_id, type_id, item_id),
        location: location::attach(assembly_id, location_hash),
        metadata: option::none(),
    };

    event::emit(AssemblyCreatedEvent {
        assembly_id,
        type_id,
        item_id,
        volume,
    });
    assembly
}

public fun share_assembly(assembly: Assembly, _: &AdminCap) {
    transfer::share_object(assembly);
}

// TODO: this is a placeholder, the implementation may change based on discussions with game design
public fun unanchor(assembly: Assembly, _: &AdminCap) {
    let Assembly {
        id,
        type_id: _,
        item_id: _,
        volume: _,
        status,
        location,
        metadata,
    } = assembly;

    location.remove();
    status.unanchor();
    if (metadata.is_some()) {
        let _meta_data = metadata.destroy_some();
        _meta_data.delete();
    } else {
        metadata.destroy_none();
    };

    // deleting doesnt mean the object id can be reclaimed.
    // however right now according to game design you cannot anchor after unanchor so its safe
    object::delete(id);
    // In future we can do
    // derived_object::reclaim(&mut assembly_registry, id);
}

// === Package Functions ===
public(package) fun borrow_registry_id(registry: &mut AssemblyRegistry): &mut UID {
    &mut registry.id
}

public(package) fun assembly_exists(registry: &AssemblyRegistry, item_id: u64): bool {
    derived_object::exists(&registry.id, item_id)
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun location(assembly: &Assembly): &Location {
    &assembly.location
}
