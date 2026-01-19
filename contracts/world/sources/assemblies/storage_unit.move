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
module world::storage_unit;

use std::type_name::{Self, TypeName};
use sui::{clock::Clock, derived_object, dynamic_field as df, event};
use world::{
    access::{Self, OwnerCap, AdminCap, ServerAddressRegistry, AdminACL},
    character::Character,
    energy::EnergyConfig,
    in_game_id::{Self, TenantItemId},
    inventory::{Self, Inventory, Item},
    location::{Self, Location},
    metadata::{Self, Metadata},
    network_node::{NetworkNode, OfflineAssemblies},
    object_registry::ObjectRegistry,
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
#[error(code = 8)]
const EUnauthorizedSponsor: vector<u8> = b"Unauthorized sponsor";
#[error(code = 9)]
const ETransactionNotSponsored: vector<u8> = b"Transaction not sponsored";
#[error(code = 10)]
const ENetworkNodeMismatch: vector<u8> =
    b"Provided network node does not match the storage unit's configured energy source";
#[error(code = 11)]
const EStorageUnitInvalidState: vector<u8> = b"Storage Unit should be offline";

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
    energy_source_id: ID,
    metadata: Option<Metadata>,
    extension: Option<TypeName>,
}

// === Events ===
public struct StorageUnitCreatedEvent has copy, drop {
    storage_unit_id: ID,
    assembly_key: TenantItemId,
    owner_cap_id: ID,
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
    assert!(access::is_authorized(owner_cap, object::id(storage_unit)), EAssemblyNotAuthorized);
    storage_unit.extension.swap_or_fill(type_name::with_defining_ids<Auth>());
}

public fun online(
    storage_unit: &mut StorageUnit,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    owner_cap: &OwnerCap<StorageUnit>,
) {
    assert!(access::is_authorized(owner_cap, object::id(storage_unit)), EAssemblyNotAuthorized);
    assert!(storage_unit.energy_source_id == object::id(network_node), ENetworkNodeMismatch);
    reserve_energy(storage_unit, network_node, energy_config);

    storage_unit.status.online();
}

public fun offline(
    storage_unit: &mut StorageUnit,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    owner_cap: &OwnerCap<StorageUnit>,
) {
    assert!(access::is_authorized(owner_cap, object::id(storage_unit)), EAssemblyNotAuthorized);

    // Verify network node matches the storage unit's energy source
    assert!(storage_unit.energy_source_id == object::id(network_node), ENetworkNodeMismatch);
    release_energy(storage_unit, network_node, energy_config);

    storage_unit.status.offline();
}

/// Bridges items from chain to game inventory
public fun chain_item_to_game_inventory<T: key>(
    storage_unit: &mut StorageUnit,
    server_registry: &ServerAddressRegistry,
    owner_cap: &OwnerCap<T>,
    character: &Character,
    type_id: u64,
    quantity: u32,
    location_proof: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    check_inventory_authorization(owner_cap, storage_unit, character.id());
    assert!(storage_unit.status.is_online(), ENotOnline);

    let owner_cap_id = object::id(owner_cap);
    let inventory = df::borrow_mut<ID, Inventory>(
        &mut storage_unit.id,
        owner_cap_id,
    );
    inventory.burn_items_with_proof(
        character,
        server_registry,
        &storage_unit.location,
        location_proof,
        type_id,
        quantity,
        clock,
        ctx,
    );
}

public fun deposit_item<Auth: drop>(
    storage_unit: &mut StorageUnit,
    character: &Character,
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
    inventory.deposit_item(character, item);
}

public fun withdraw_item<Auth: drop>(
    storage_unit: &mut StorageUnit,
    character: &Character,
    _: Auth,
    type_id: u64,
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

    inventory.withdraw_item(character, type_id)
}

public fun deposit_by_owner<T: key>(
    storage_unit: &mut StorageUnit,
    item: Item,
    server_registry: &ServerAddressRegistry,
    owner_cap: &OwnerCap<T>,
    character: &Character,
    proximity_proof: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let owner_cap_id = object::id(owner_cap);
    assert!(storage_unit.status.is_online(), ENotOnline);
    check_inventory_authorization(owner_cap, storage_unit, character.id());
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

    inventory.deposit_item(character, item);
}

public fun withdraw_by_owner<T: key>(
    storage_unit: &mut StorageUnit,
    server_registry: &ServerAddressRegistry,
    owner_cap: &OwnerCap<T>,
    character: &Character,
    type_id: u64,
    proximity_proof: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
): Item {
    let owner_cap_id = object::id(owner_cap);
    assert!(storage_unit.status.is_online(), ENotOnline);
    check_inventory_authorization(owner_cap, storage_unit, character.id());

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

    inventory.withdraw_item(character, type_id)
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
    registry: &mut ObjectRegistry,
    network_node: &mut NetworkNode,
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
    assert!(!registry.object_exists(storage_unit_key), EStorageUnitAlreadyExists);

    let assembly_uid = derived_object::claim(registry.borrow_registry_id(), storage_unit_key);
    let assembly_id = object::uid_to_inner(&assembly_uid);
    let network_node_id = object::id(network_node);

    // Create owner cap
    let owner_cap_id = access::create_and_transfer_owner_cap<StorageUnit>(
        admin_cap,
        assembly_id,
        character.character_address(),
        ctx,
    );

    let mut storage_unit = StorageUnit {
        id: assembly_uid,
        key: storage_unit_key,
        owner_cap_id,
        type_id: type_id,
        status: status::anchor(assembly_id, type_id, item_id),
        location: location::attach(assembly_id, location_hash),
        inventory_keys: vector[],
        energy_source_id: network_node_id,
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

    network_node.connect_assembly(assembly_id);

    let inventory = inventory::create(
        assembly_id,
        storage_unit_key,
        owner_cap_id,
        max_capacity,
    );

    storage_unit.inventory_keys.push_back(owner_cap_id);
    df::add(&mut storage_unit.id, owner_cap_id, inventory);

    event::emit(StorageUnitCreatedEvent {
        storage_unit_id: assembly_id,
        assembly_key: storage_unit_key,
        owner_cap_id,
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

public fun update_energy_source(
    storage_unit: &mut StorageUnit,
    network_node: &mut NetworkNode,
    _: &AdminCap,
) {
    let storage_unit_id = object::id(storage_unit);
    let nwn_id = object::id(network_node);
    assert!(!storage_unit.status.is_online(), EStorageUnitInvalidState);

    network_node.connect_assembly(storage_unit_id);
    storage_unit.energy_source_id = nwn_id;
}

//  TODO : Can we generalise this function for all assembly
/// Brings a connected storage unit offline and removes it from the hot potato
/// Must be called for each storage unit in the hot potato list
/// Returns the updated hot potato with the processed storage unit removed
/// After all storage units are processed, call destroy_offline_assemblies to consume the hot potato
/// The hot potato itself serves as authorization since it can only be obtained from capped functions
public fun offline_connected_storage_unit(
    storage_unit: &mut StorageUnit,
    mut offline_assemblies: OfflineAssemblies,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
): OfflineAssemblies {
    if (offline_assemblies.ids_length() > 0) {
        let storage_unit_id = object::id(storage_unit);

        // Remove the storage unit ID from the hot potato using package function
        let found = offline_assemblies.remove_assembly_id(storage_unit_id);
        if (found) {
            // Bring the storage unit offline if it's online and release energy
            if (storage_unit.status.is_online()) {
                storage_unit.status.offline();
                release_energy(storage_unit, network_node, energy_config);
            };
        }
    };
    offline_assemblies
}

// On unanchor the storage unit is scooped back into inventory in game
// So we burn the items and delete the object
public fun unanchor(
    storage_unit: StorageUnit,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    character: &Character,
    _: &AdminCap,
) {
    let StorageUnit {
        mut id,
        status,
        location,
        inventory_keys,
        metadata,
        energy_source_id,
        type_id,
        ..,
    } = storage_unit;

    assert!(energy_source_id == object::id(network_node), ENetworkNodeMismatch);

    // Release energy if storage unit is online
    if (status.is_online()) {
        release_energy_by_type(network_node, energy_config, type_id);
    };

    // Disconnect storage unit from network node
    let storage_unit_id = object::uid_to_inner(&id);
    network_node.disconnect_assembly(storage_unit_id);

    status.unanchor();
    location.remove();

    // loop through inventory_keys
    inventory_keys.destroy!(|key| df::remove<ID, Inventory>(&mut id, key).delete(character));
    metadata.do!(|metadata| metadata.delete());
    id.delete();
}

/// Bridges items from game to chain inventory
public fun game_item_to_chain_inventory<T: key>(
    storage_unit: &mut StorageUnit,
    admin_acl: &AdminACL,
    owner_cap: &OwnerCap<T>,
    character: &Character,
    item_id: u64,
    type_id: u64,
    volume: u64,
    quantity: u32,
    ctx: &mut TxContext,
) {
    let sponsor_opt = tx_context::sponsor(ctx);
    assert!(option::is_some(&sponsor_opt), ETransactionNotSponsored);
    let sponsor = *option::borrow(&sponsor_opt);
    assert!(admin_acl.is_authorized_sponsor(sponsor), EUnauthorizedSponsor);

    let owner_cap_id = object::id(owner_cap);
    assert!(storage_unit.status.is_online(), ENotOnline);
    check_inventory_authorization(owner_cap, storage_unit, character.id());

    // create a ephemeral inventory if it does not exists for a character
    if (!df::exists_(&storage_unit.id, owner_cap_id)) {
        let owner_inv = df::borrow<ID, Inventory>(
            &storage_unit.id,
            storage_unit.owner_cap_id,
        );
        let inventory = inventory::create(
            object::id(storage_unit),
            storage_unit.key,
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
        character,
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
fun reserve_energy(
    storage_unit: &StorageUnit,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
) {
    network_node
        .borrow_energy_source()
        .reserve_energy(
            energy_config,
            storage_unit.type_id,
        );
}

fun release_energy(
    storage_unit: &StorageUnit,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
) {
    release_energy_by_type(network_node, energy_config, storage_unit.type_id);
}

fun release_energy_by_type(
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    type_id: u64,
) {
    network_node
        .borrow_energy_source()
        .release_energy(
            energy_config,
            type_id,
        );
}

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
        assert!(access::is_authorized(owner_cap, storage_unit_id), EInventoryNotAuthorized);
    } else if (owner_cap_type == type_name::with_defining_ids<Character>()) {
        assert!(access::is_authorized(owner_cap, character_id), EInventoryNotAuthorized);
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
public fun item_quantity(storage_unit: &StorageUnit, owner_cap_id: ID, type_id: u64): u32 {
    let inventory = df::borrow<ID, Inventory>(&storage_unit.id, owner_cap_id);
    inventory.item_quantity(type_id)
}

#[test_only]
public fun contains_item(storage_unit: &StorageUnit, owner_cap_id: ID, type_id: u64): bool {
    let inventory = df::borrow<ID, Inventory>(&storage_unit.id, owner_cap_id);
    inventory.contains_item(type_id)
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
    character: &Character,
    type_id: u64,
    quantity: u32,
    location_proof: vector<u8>,
    ctx: &mut TxContext,
) {
    let owner_cap_id = object::id(owner_cap);
    check_inventory_authorization(owner_cap, storage_unit, character.id());
    assert!(storage_unit.status.is_online(), ENotOnline);

    let inventory = df::borrow_mut<ID, Inventory>(&mut storage_unit.id, owner_cap_id);
    inventory.burn_items_with_proof_test(
        character,
        server_registry,
        &storage_unit.location,
        location_proof,
        type_id,
        quantity,
        ctx,
    );
}

#[test_only]
public fun game_item_to_chain_inventory_test<T: key>(
    storage_unit: &mut StorageUnit,
    admin_acl: &AdminACL,
    owner_cap: &OwnerCap<T>,
    character: &Character,
    item_id: u64,
    type_id: u64,
    volume: u64,
    quantity: u32,
    ctx: &mut TxContext,
) {
    assert!(admin_acl.is_authorized_sponsor(ctx.sender()), EUnauthorizedSponsor);

    let owner_cap_id = object::id(owner_cap);
    assert!(storage_unit.status.is_online(), ENotOnline);
    check_inventory_authorization(owner_cap, storage_unit, character.id());

    // create a ephemeral inventory if it does not exists for a character
    if (!df::exists_(&storage_unit.id, owner_cap_id)) {
        let owner_inv = df::borrow<ID, Inventory>(
            &storage_unit.id,
            storage_unit.owner_cap_id,
        );
        let inventory = inventory::create(
            object::id(storage_unit),
            storage_unit.key,
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
        character,
        storage_unit.key.tenant(),
        item_id,
        type_id,
        volume,
        quantity,
        storage_unit.location.hash(),
        ctx,
    )
}
