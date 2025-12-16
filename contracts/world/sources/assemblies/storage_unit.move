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
use sui::{clock::Clock, derived_object, dynamic_field as df, event};
use world::{
    assembly::{Self, AssemblyRegistry},
    authority::{Self, OwnerCap, AdminCap, ServerAddressRegistry},
    character::Character,
    in_game_id::{Self, TenantItemId},
    inventory::{Self, Inventory, Item},
    location::{Self, Location},
    metadata::{Self, Metadata},
    status::{Self, AssemblyStatus, Status}
};

// === Errors ===
#[error(code = 0)]
const EStorageUnitTypeIdEmpty: vector<u8> = b"StorageUnit TypeId is empty";
#[error(code = 1)]
const EStorageUnitItemIdEmpty: vector<u8> = b"StorageUnit ItemId is empty";
#[error(code = 2)]
const EStorageUnitAlreadyExists: vector<u8> = b"StorageUnit with the same Item Id already exists";
#[error(code = 3)]
const EAssemblyNotAuthorized: vector<u8> = b"StorageUnit access not authorized";
#[error(code = 4)]
const EExtensionNotAuthorized: vector<u8> =
    b"Access only authorized for the custom contract of the registered type";
#[error(code = 5)]
const EInventoryNotAuthorized: vector<u8> = b"Inventory Access not authorized";
#[error(code = 6)]
const ENotOnline: vector<u8> = b"Storage Unit is not online";
#[error(code = 7)]
const ETenantMismatch: vector<u8> = b"Item cannot be transferred across tenants";

// Future thought: Can we make the behaviour attached dynamically using dof
// === Structs ===
public struct StorageUnit has key {
    id: UID,
    key: TenantItemId,
    owner_cap_id: ID,
    type_id: u64,
    status: AssemblyStatus,
    location: Location,
    inventory_keys: vector<ID>,
    metadata: Option<Metadata>,
    extension: Option<TypeName>,
}

// === Events ===
public struct StorageUnitCreatedEvent has copy, drop {
    storage_unit_id: ID,
    key: TenantItemId,
    type_id: u64,
    max_capacity: u64,
    location_hash: vector<u8>,
    status: Status,
}

// === Public Functions ===
public fun authorize_extension<Auth: drop>(
    storage_unit: &mut StorageUnit,
    owner_cap: &OwnerCap<StorageUnit>,
) {
    assert!(authority::is_authorized(owner_cap, object::id(storage_unit)), EAssemblyNotAuthorized);
    storage_unit.extension.swap_or_fill(type_name::with_defining_ids<Auth>());
}

// We can do wrappers like this, or directly call respective modules
public fun online(storage_unit: &mut StorageUnit, owner_cap: &OwnerCap<StorageUnit>) {
    assert!(authority::is_authorized(owner_cap, object::id(storage_unit)), EAssemblyNotAuthorized);
    storage_unit.status.online();
}

public fun offline(storage_unit: &mut StorageUnit, owner_cap: &OwnerCap<StorageUnit>) {
    assert!(authority::is_authorized(owner_cap, object::id(storage_unit)), EAssemblyNotAuthorized);
    storage_unit.status.offline();
}

public fun chain_item_to_game_inventory<T: key>(
    storage_unit: &mut StorageUnit,
    server_registry: &ServerAddressRegistry,
    owner_cap: &OwnerCap<T>,
    character_id: ID,
    item_id: u64,
    quantity: u32,
    location_proof: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    check_inventory_authorization(owner_cap, storage_unit, character_id);
    assert!(storage_unit.status.is_online(), ENotOnline);

    let owner_cap_id = object::id(owner_cap);
    let inventory = df::borrow_mut<ID, Inventory>(
        &mut storage_unit.id,
        owner_cap_id,
    );
    inventory.burn_items_with_proof(
        server_registry,
        &storage_unit.location,
        location_proof,
        item_id,
        quantity,
        clock,
        ctx,
    );
}

public fun deposit_item<Auth: drop>(
    storage_unit: &mut StorageUnit,
    item: Item,
    _: Auth,
    _: &mut TxContext,
) {
    assert!(
        storage_unit.extension.contains(&type_name::with_defining_ids<Auth>()),
        EExtensionNotAuthorized,
    );
    assert!(storage_unit.status.is_online(), ENotOnline);
    assert!(inventory::tenant(&item) == storage_unit.key.tenant(), ETenantMismatch);
    let inventory = df::borrow_mut<ID, Inventory>(
        &mut storage_unit.id,
        storage_unit.owner_cap_id,
    );
    inventory.deposit_item(item);
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
    let inventory = df::borrow_mut<ID, Inventory>(
        &mut storage_unit.id,
        storage_unit.owner_cap_id,
    );

    inventory.withdraw_item(item_id)
}

public fun deposit_by_owner<T: key>(
    storage_unit: &mut StorageUnit,
    item: Item,
    server_registry: &ServerAddressRegistry,
    owner_cap: &OwnerCap<T>,
    character_id: ID,
    proximity_proof: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let owner_cap_id = object::id(owner_cap);
    assert!(storage_unit.status.is_online(), ENotOnline);
    check_inventory_authorization(owner_cap, storage_unit, character_id);
    assert!(inventory::tenant(&item) == storage_unit.key.tenant(), ETenantMismatch);

    // This check is only required for ephemeral inventory
    location::verify_same_location(
        storage_unit.location.hash(),
        item.get_item_location_hash(),
    );

    location::verify_proximity_proof_from_bytes(
        server_registry,
        &storage_unit.location,
        proximity_proof,
        clock,
        ctx,
    );

    let inventory = df::borrow_mut<ID, Inventory>(
        &mut storage_unit.id,
        owner_cap_id,
    );

    inventory.deposit_item(item);
}

public fun withdraw_by_owner<T: key>(
    storage_unit: &mut StorageUnit,
    server_registry: &ServerAddressRegistry,
    owner_cap: &OwnerCap<T>,
    character_id: ID,
    item_id: u64,
    proximity_proof: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
): Item {
    let owner_cap_id = object::id(owner_cap);
    assert!(storage_unit.status.is_online(), ENotOnline);
    check_inventory_authorization(owner_cap, storage_unit, character_id);

    location::verify_proximity_proof_from_bytes(
        server_registry,
        &storage_unit.location,
        proximity_proof,
        clock,
        ctx,
    );

    let inventory = df::borrow_mut<ID, Inventory>(
        &mut storage_unit.id,
        owner_cap_id,
    );

    inventory.withdraw_item(item_id)
}

// TODO: Can also have a transfer function for simplicity

// === View Functions ===
public fun status(storage_unit: &StorageUnit): &AssemblyStatus {
    &storage_unit.status
}

public fun location(storage_unit: &StorageUnit): &Location {
    &storage_unit.location
}

public fun inventory(storage_unit: &StorageUnit, owner_cap_id: ID): &Inventory {
    df::borrow(&storage_unit.id, owner_cap_id)
}

public fun owner_cap_id(storage_unit: &StorageUnit): ID {
    storage_unit.owner_cap_id
}

// === Admin Functions ===
public fun anchor(
    assembly_registry: &mut AssemblyRegistry,
    character: &Character,
    admin_cap: &AdminCap,
    item_id: u64,
    type_id: u64,
    max_capacity: u64,
    location_hash: vector<u8>,
    ctx: &mut TxContext,
): StorageUnit {
    assert!(type_id != 0, EStorageUnitTypeIdEmpty);
    assert!(item_id != 0, EStorageUnitItemIdEmpty);

    let storage_unit_key = in_game_id::create_key(item_id, character.tenant());
    assert!(
        !assembly::assembly_exists(assembly_registry, storage_unit_key),
        EStorageUnitAlreadyExists,
    );

    let registry_id = assembly::borrow_registry_id(assembly_registry);
    let assembly_uid = derived_object::claim(registry_id, item_id);
    let assembly_id = object::uid_to_inner(&assembly_uid);

    // Create owner cap first with just the ID
    let owner_cap = authority::create_owner_cap_by_id<StorageUnit>(admin_cap, assembly_id, ctx);
    let owner_cap_id = object::id(&owner_cap);

    let mut storage_unit = StorageUnit {
        id: assembly_uid,
        key: storage_unit_key,
        owner_cap_id,
        type_id: type_id,
        status: status::anchor(assembly_id, type_id, item_id),
        location: location::attach(assembly_id, location_hash),
        inventory_keys: vector[],
        metadata: std::option::some(
            metadata::create_metadata(
                assembly_id,
                item_id,
                b"".to_string(),
                b"".to_string(),
                b"".to_string(),
            ),
        ),
        extension: option::none(),
    };

    // Create ownerCap for storage unit
    authority::transfer_owner_cap(owner_cap, character.character_address(), ctx);

    let inventory = inventory::create(
        assembly_id,
        owner_cap_id,
        max_capacity,
    );

    storage_unit.inventory_keys.push_back(owner_cap_id);
    df::add(&mut storage_unit.id, owner_cap_id, inventory);

    event::emit(StorageUnitCreatedEvent {
        storage_unit_id: assembly_id,
        key: storage_unit_key,
        type_id: type_id,
        max_capacity,
        location_hash,
        status: status::status(&storage_unit.status),
    });

    storage_unit
}

public fun share_storage_unit(storage_unit: StorageUnit, _: &AdminCap) {
    transfer::share_object(storage_unit);
}

// On unanchor the storage unit is scooped back into inventory in game
// So we burn the items and delete the object
public fun unanchor(storage_unit: StorageUnit, _: &AdminCap) {
    let StorageUnit {
        mut id,
        status,
        location,
        inventory_keys,
        metadata,
        ..,
    } = storage_unit;

    status.unanchor();
    location.remove();

    // loop through inventory_keys
    inventory_keys.destroy!(|key| df::remove<ID, Inventory>(&mut id, key).delete());
    metadata.do!(|metadata| metadata.delete());
    id.delete();
}

public fun game_item_to_chain_inventory<T: key>(
    storage_unit: &mut StorageUnit,
    _: &AdminCap,
    owner_cap: &OwnerCap<T>,
    character_id: ID,
    item_id: u64,
    type_id: u64,
    volume: u64,
    quantity: u32,
    ctx: &mut TxContext,
) {
    let owner_cap_id = object::id(owner_cap);
    assert!(storage_unit.status.is_online(), ENotOnline);
    check_inventory_authorization(owner_cap, storage_unit, character_id);

    // create a ephemeral inventory if it does not exists for a character
    if (!df::exists_(&storage_unit.id, owner_cap_id)) {
        let owner_inv = df::borrow<ID, Inventory>(
            &storage_unit.id,
            storage_unit.owner_cap_id,
        );
        let inventory = inventory::create(
            object::id(storage_unit),
            owner_cap_id,
            owner_inv.max_capacity(),
        );

        storage_unit.inventory_keys.push_back(owner_cap_id);
        df::add(&mut storage_unit.id, owner_cap_id, inventory);
    };

    let inventory = df::borrow_mut<ID, Inventory>(
        &mut storage_unit.id,
        owner_cap_id,
    );
    inventory.mint_items(
        storage_unit.key.tenant(),
        item_id,
        type_id,
        volume,
        quantity,
        storage_unit.location.hash(),
        ctx,
    )
}

// === Private Functions ===
fun check_inventory_authorization<T: key>(
    owner_cap: &OwnerCap<T>,
    storage_unit: &StorageUnit,
    character_id: ID,
) {
    // If OwnerCap type is StorageUnit then check if authorised object id is storage unit id
    // else if its Character type then the authorized object id is character id
    let owner_cap_type = type_name::with_defining_ids<T>();
    let storage_unit_id = object::id(storage_unit);

    if (owner_cap_type == type_name::with_defining_ids<StorageUnit>()) {
        assert!(authority::is_authorized(owner_cap, storage_unit_id), EInventoryNotAuthorized);
    } else if (owner_cap_type == type_name::with_defining_ids<Character>()) {
        assert!(authority::is_authorized(owner_cap, character_id), EInventoryNotAuthorized);
    } else {
        assert!(false, EInventoryNotAuthorized);
    };
}

// === Test Functions ===
#[test_only]
public fun inventory_mut(storage_unit: &mut StorageUnit, owner_cap_id: ID): &mut Inventory {
    df::borrow_mut<ID, Inventory>(&mut storage_unit.id, owner_cap_id)
}

#[test_only]
public fun borrow_status_mut(storage_unit: &mut StorageUnit): &mut AssemblyStatus {
    &mut storage_unit.status
}

#[test_only]
public fun item_quantity(storage_unit: &StorageUnit, owner_cap_id: ID, item_id: u64): u32 {
    let inventory = df::borrow<ID, Inventory>(&storage_unit.id, owner_cap_id);
    inventory.item_quantity(item_id)
}

#[test_only]
public fun contains_item(storage_unit: &StorageUnit, owner_cap_id: ID, item_id: u64): bool {
    let inventory = df::borrow<ID, Inventory>(&storage_unit.id, owner_cap_id);
    inventory.contains_item(item_id)
}

#[test_only]
public fun inventory_keys(storage_unit: &StorageUnit): vector<ID> {
    storage_unit.inventory_keys
}

#[test_only]
public fun has_inventory(storage_unit: &StorageUnit, owner_cap_id: ID): bool {
    df::exists_(&storage_unit.id, owner_cap_id)
}

#[test_only]
public fun chain_item_to_game_inventory_test<T: key>(
    storage_unit: &mut StorageUnit,
    server_registry: &ServerAddressRegistry,
    owner_cap: &OwnerCap<T>,
    character_id: ID,
    item_id: u64,
    quantity: u32,
    location_proof: vector<u8>,
    ctx: &mut TxContext,
) {
    let owner_cap_id = object::id(owner_cap);
    check_inventory_authorization(owner_cap, storage_unit, character_id);
    assert!(storage_unit.status.is_online(), ENotOnline);

    let inventory = df::borrow_mut<ID, Inventory>(&mut storage_unit.id, owner_cap_id);
    inventory.burn_items_with_proof_test(
        server_registry,
        &storage_unit.location,
        location_proof,
        item_id,
        quantity,
        ctx,
    );
}
