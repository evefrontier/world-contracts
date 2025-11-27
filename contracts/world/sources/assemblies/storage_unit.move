/// This module handles the functionality of the in-game Storage Unit Assembly
///
/// The Storage Unit is a programmable, on-chain storage structure.
/// It can allow players to store, withdraw, and manage items under rules they design themselves.
/// The behaviour of a Storage Unit can be customized by registering a custom contract
/// using the typed witness pattern. https://github.com/evefrontier/world-contracts/blob/main/docs/architechture.md#layer-3-player-extensions-moddability
///
/// Storage Units support two access modes to enable player-to-player interactions:
///
/// 1. **Extension-based access** (Primary):
///    - Functions: `deposit_item<Auth>`, `withdraw_item<Auth>`
///    - Allows 3rd party contracts to handle inventory operations on behalf of the owner
///
/// 2. **Owner-direct access** (Temporary / Ephemeral Storage)
///    - Functions: `deposit_by_owner`, `withdraw_by_owner`
///    - Allows the owner to handle inventory operations
///    - Will be deprecated once the Ship inventory module is implemented
///    - Ships will handle owner-controlled inventory operations in the future
///
/// Future pattern: Storage Units (extension-controlled), Ships (owner-controlled)
/// Example on how a storage unit can be customised : //todo:
module world::storage_unit;

use std::type_name::{Self, TypeName};
use sui::{clock::Clock, event};
use world::{
    authority::{Self, OwnerCap, AdminCap, ServerAddressRegistry},
    inventory::{Self, Inventory, Item},
    location::{Self, Location},
    status::{Self, AssemblyStatus, Status}
};

// === Errors ===
#[error(code = 0)]
const EAccessNotAuthorized: vector<u8> = b"Owner Access not authorised for this Storage Unit";
#[error(code = 1)]
const EExtensionNotAuthorized: vector<u8> =
    b"Access only authorised for the custom contract of the registered type";

// TODO: Add a metadata property
// Future thought: Can we make the behaviour attached dynamically using dof
// === Structs ===
public struct StorageUnit has key {
    id: UID,
    type_id: u64,
    item_id: u64,
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
    type_id: u64,
    item_id: u64,
}

// === Public Functions ===
public fun authorize_extension<Auth: drop>(storage_unit: &mut StorageUnit, owner_cap: &OwnerCap) {
    assert!(authority::is_authorized(owner_cap, object::id(storage_unit)), EAccessNotAuthorized);
    storage_unit.extension.swap_or_fill(type_name::with_defining_ids<Auth>());
}

// === View Functions ===

public fun status(storage_unit: &StorageUnit): &AssemblyStatus {
    &storage_unit.status
}

public fun location(storage_unit: &StorageUnit): &Location {
    &storage_unit.location
}

public fun inventory(storage_unit: &StorageUnit): &Inventory {
    &storage_unit.inventory
}

// === Admin Functions ===
public fun create_storage_unit(
    admin_cap: &AdminCap,
    type_id: u64,
    item_id: u64,
    max_capacity: u64,
    location_hash: vector<u8>,
    ctx: &mut TxContext,
): StorageUnit {
    // TODO: Make this a derived id
    let assembly_uid = object::new(ctx);
    let assembly_id = object::uid_to_inner(&assembly_uid);
    let storage_unit = StorageUnit {
        id: assembly_uid,
        type_id: type_id,
        item_id: item_id,
        status: status::anchor(admin_cap, assembly_id),
        location: location::attach_location(admin_cap, assembly_id, location_hash),
        inventory: inventory::create(admin_cap, max_capacity, assembly_id),
        extension: option::none(),
    };

    event::emit(StorageUnitCreatedEvent {
        storage_unit_id: assembly_id,
        max_capacity,
        location_hash,
        status: status::status(&storage_unit.status),
        type_id: type_id,
        item_id: item_id,
    });

    storage_unit
}

public fun share_storage_unit(storage_unit: StorageUnit, _: &AdminCap) {
    transfer::share_object(storage_unit);
}

// We can do wrappers like this, or directly call respective modules
public fun online(storage_unit: &mut StorageUnit, owner_cap: &OwnerCap) {
    storage_unit.status.online(owner_cap);
}

public fun game_item_to_chain_inventory(
    storage_unit: &mut StorageUnit,
    admin_cap: &AdminCap,
    item_id: u64,
    type_id: u64,
    volume: u64,
    quantity: u32,
    ctx: &mut TxContext,
) {
    storage_unit
        .inventory
        .mint_items(
            &storage_unit.status,
            admin_cap,
            item_id,
            type_id,
            volume,
            quantity,
            storage_unit.location.hash(),
            ctx,
        )
}

public fun chain_item_to_game_inventory(
    storage_unit: &mut StorageUnit,
    server_registry: &ServerAddressRegistry,
    location_proof: vector<u8>,
    owner_cap: &OwnerCap,
    item_id: u64,
    quantity: u32,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    storage_unit
        .inventory
        .burn_items_with_proof(
            &storage_unit.status,
            &storage_unit.location,
            owner_cap,
            item_id,
            quantity,
            server_registry,
            location_proof,
            clock,
            ctx,
        );
}

public fun deposit_item<Auth: drop>(
    storage_unit: &mut StorageUnit,
    _: Auth,
    item: Item,
    _: &mut TxContext,
) {
    assert!(
        storage_unit.extension.contains(&type_name::with_defining_ids<Auth>()),
        EExtensionNotAuthorized,
    );
    storage_unit.inventory.deposit_item(item);
}

public fun withdraw_item<Auth: drop>(
    storage_unit: &mut StorageUnit,
    _: Auth,
    item_id: u64,
    _: &mut TxContext,
): Item {
    assert!(
        storage_unit.extension.contains(&type_name::with_defining_ids<Auth>()),
        EExtensionNotAuthorized,
    );
    storage_unit.inventory.withdraw_item(item_id)
}

// The ephemeral storage functions will be removed when Ship inventory is implemented
// Future: The Ship module will handle owner-controlled inventory operations
public fun deposit_by_owner(
    storage_unit: &mut StorageUnit,
    item: Item,
    owner_cap: &OwnerCap,
    server_registry: &ServerAddressRegistry,
    proximity_proof: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(authority::is_authorized(owner_cap, object::id(storage_unit)), EAccessNotAuthorized);

    // This check is only required for ephemeral inventory
    location::verify_same_location(
        storage_unit.location.hash(),
        item.get_item_location_hash(),
    );

    location::verify_proximity_proof_from_bytes(
        &storage_unit.location,
        proximity_proof,
        server_registry,
        clock,
        ctx,
    );
    storage_unit.inventory.deposit_item(item);
}

public fun withdraw_by_owner(
    storage_unit: &mut StorageUnit,
    owner_cap: &OwnerCap,
    item_id: u64,
    server_registry: &ServerAddressRegistry,
    proximity_proof: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
): Item {
    assert!(authority::is_authorized(owner_cap, object::id(storage_unit)), EAccessNotAuthorized);
    location::verify_proximity_proof_from_bytes(
        &storage_unit.location,
        proximity_proof,
        server_registry,
        clock,
        ctx,
    );

    storage_unit.inventory.withdraw_item(item_id)
}

// TODO: Can also have a transfer function for simplicity

// === Test Functions ===
#[test_only]
public fun inventory_mut(storage_unit: &mut StorageUnit): &mut Inventory {
    &mut storage_unit.inventory
}

#[test_only]
public fun borrow_status_mut(storage_unit: &mut StorageUnit): &mut AssemblyStatus {
    &mut storage_unit.status
}

#[test_only]
public fun item_quantity(storage_unit: &StorageUnit, item_id: u64): u32 {
    storage_unit.inventory.item_quantity(item_id)
}

#[test_only]
public fun contains_item(storage_unit: &StorageUnit, item_id: u64): bool {
    storage_unit.inventory.contains_item(item_id)
}

#[test_only]
public fun chain_item_to_game_inventory_test(
    storage_unit: &mut StorageUnit,
    server_registry: &ServerAddressRegistry,
    location_proof: vector<u8>,
    owner_cap: &OwnerCap,
    item_id: u64,
    quantity: u32,
    ctx: &mut TxContext,
) {
    storage_unit
        .inventory
        .burn_items_with_proof_test(
            &storage_unit.status,
            &storage_unit.location,
            owner_cap,
            item_id,
            quantity,
            server_registry,
            location_proof,
            ctx,
        );
}
