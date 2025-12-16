/// This module handles all the operations for generalized assemblies
/// Basic operations are anchor, unanchor, online, offline and destroy
module world::assembly;

use std::string::String;
use sui::{derived_object, event};
use world::{
    access::{Self, AdminCap, OwnerCap},
    in_game_id::{Self, TenantItemId},
    location::{Self, Location},
    metadata::{Self, Metadata},
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
    key: TenantItemId,
    owner_cap_id: ID,
    type_id: u64,
    volume: u64,
    status: AssemblyStatus,
    location: Location,
    metadata: Option<Metadata>,
}

// === Events ===
public struct AssemblyCreatedEvent has copy, drop {
    assembly_id: ID,
    key: TenantItemId,
    type_id: u64,
    volume: u64,
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(AssemblyRegistry {
        id: object::new(ctx),
    });
}

// === Public Functions ===
public fun online(assembly: &mut Assembly, owner_cap: &OwnerCap<Assembly>) {
    assert!(access::is_authorized(owner_cap, object::id(assembly)), EAssemblyNotAuthorized);
    assembly.status.online();
}

public fun offline(assembly: &mut Assembly, owner_cap: &OwnerCap<Assembly>) {
    assert!(access::is_authorized(owner_cap, object::id(assembly)), EAssemblyNotAuthorized);
    assembly.status.offline();
}

// === View Functions ===
public fun status(assembly: &Assembly): &AssemblyStatus {
    &assembly.status
}

// === Admin Functions ===
public fun anchor(
    assembly_registry: &mut AssemblyRegistry,
    admin_cap: &AdminCap,
    character_address: address,
    tenant: String,
    item_id: u64,
    type_id: u64,
    volume: u64,
    location_hash: vector<u8>,
    ctx: &mut TxContext,
): Assembly {
    assert!(type_id != 0, EAssemblyTypeIdEmpty);
    assert!(item_id != 0, EAssemblyItemIdEmpty);

    // key to derive assembly object id
    let assembly_key = in_game_id::create_key(item_id, tenant);
    assert!(!assembly_exists(assembly_registry, assembly_key), EAssemblyAlreadyExists);

    let assembly_uid = derived_object::claim(&mut assembly_registry.id, assembly_key);
    let assembly_id = object::uid_to_inner(&assembly_uid);

    // Create owner cap first with just the ID
    let owner_cap_id = access::create_and_transfer_owner_cap<Assembly>(
        admin_cap,
        assembly_id,
        character_address,
        ctx,
    );

    let assembly = Assembly {
        id: assembly_uid,
        key: assembly_key,
        owner_cap_id,
        type_id,
        volume,
        status: status::anchor(assembly_id, type_id, item_id),
        location: location::attach(assembly_id, location_hash),
        metadata: std::option::some(
            metadata::create_metadata(
                assembly_id,
                item_id,
                b"".to_string(),
                b"".to_string(),
                b"".to_string(),
            ),
        ),
    };

    event::emit(AssemblyCreatedEvent {
        assembly_id,
        key: assembly_key,
        type_id,
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
        status,
        location,
        metadata,
        ..,
    } = assembly;

    location.remove();
    status.unanchor();
    metadata.do!(|metadata| metadata.delete());

    // deleting doesnt mean the object id can be reclaimed.
    // however right now according to game design you cannot anchor after unanchor so its safe
    id.delete();
    // In future we can do
    // derived_object::reclaim(&mut assembly_registry, id);
}

// === Package Functions ===
public(package) fun borrow_registry_id(registry: &mut AssemblyRegistry): &mut UID {
    &mut registry.id
}

public(package) fun assembly_exists(registry: &AssemblyRegistry, key: TenantItemId): bool {
    derived_object::exists(&registry.id, key)
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun location(assembly: &Assembly): &Location {
    &assembly.location
}
