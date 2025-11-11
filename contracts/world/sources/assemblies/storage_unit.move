/// This module handles the functionalities of in-game Storage Unit Assembly
///
/// The Storage Unit is a programmable, on-chain storage structure
/// that allows players to store, withdraw, and manage items under rules they design themselves.
/// The behaviour of a Storage Unit can be customized by registering a custom contract
/// using the typed witness pattern.
///
/// More information: https://github.com/evefrontier/world-contracts/blob/main/docs/architechture.md#layer-3-player-extensions-moddability

module world::storage_unit;

use std::type_name::{Self, TypeName};
use sui::event;
use world::{
    authority::{Self, OwnerCap, AdminCap},
    inventory::{Self, Inventory, Item},
    location::{Self, Location},
    status::{Self, AssemblyStatus, Status}
};

// === Errors ===
#[error(code = 0)]
const EAccessNotAuthorized: vector<u8> = b"Access not authorised for this Storage Unit";
#[error(code = 1)]
const ENotAuthorized: vector<u8> =
    b"Access only authorised for the custom contract of the registered type";

// === Structs ===
public struct StorageUnit has key {
    id: UID,
    status: AssemblyStatus,
    location: Location,
    inventory: Inventory,
    extension: Option<TypeName>,
}

// === Events ===
public struct StorageUnitCreatedEvent has copy, drop {
    storage_unit_id: ID,
    max_capacity: u64,
    location_hash: vector<u8>,
    status: Status,
}

// === View Functions ===

// === Public Functions ===
public fun authorize_software<Auth: drop>(storage_unit: &mut StorageUnit, owner_cap: &OwnerCap) {
    assert!(authority::is_authorized(owner_cap, object::id(storage_unit)), EAccessNotAuthorized);
    storage_unit.extension.swap_or_fill(type_name::with_defining_ids<Auth>());
}

// === Admin Functions ===
public fun create_storage_unit(
    admin_cap: &AdminCap,
    max_capacity: u64,
    location_hash: vector<u8>,
    ctx: &mut TxContext,
): StorageUnit {
    let assembly_uid = object::new(ctx);
    let assembly_id = object::uid_to_inner(&assembly_uid);
    let storage_unit = StorageUnit {
        id: assembly_uid,
        status: status::anchor(admin_cap, assembly_id),
        location: location::attach_location(admin_cap, assembly_id, location_hash),
        inventory: inventory::create(admin_cap, max_capacity, assembly_id),
        extension: option::none(),
    };

    event::emit(StorageUnitCreatedEvent {
        storage_unit_id: assembly_id,
        max_capacity,
        location_hash,
        status: status::get_status(&storage_unit.status),
    });

    storage_unit
}

// Should we rename the function ?
public fun game_to_chain_inventory(
    storage_unit: &mut StorageUnit,
    admin_cap: &AdminCap,
    item_id: u64,
    type_id: u64,
    volume: u64,
    quantity: u64,
    ctx: &mut TxContext,
) {
    storage_unit
        .inventory
        .mint_items_in_inventory(
            &storage_unit.status,
            storage_unit.location.get_hash(),
            admin_cap,
            item_id,
            type_id,
            volume,
            quantity,
            ctx,
        )
}

public fun deposit_to_inventory<Auth: drop>(
    storage_unit: &mut StorageUnit,
    _: Auth,
    item: Item,
    _: &mut TxContext,
) {
    assert!(storage_unit.extension.contains(&type_name::with_defining_ids<Auth>()), ENotAuthorized);
    storage_unit.inventory.deposit_item(item);
}

public fun withdraw_from_inventory<Auth: drop>(
    storage_unit: &mut StorageUnit,
    _: Auth,
    item_id: u64,
    _: &mut TxContext,
): Item {
    assert!(storage_unit.extension.contains(&type_name::with_defining_ids<Auth>()), ENotAuthorized);
    storage_unit.inventory.withdraw_item(item_id)
}

// === Test Functions ===
#[test_only]
public fun get_item_amount(storage_unit: &StorageUnit, item_id: u64): u64 {
    storage_unit.inventory.get_item_amount(item_id)
}
