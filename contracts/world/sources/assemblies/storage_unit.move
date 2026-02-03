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
    network_node::{NetworkNode, OfflineAssemblies, HandleOrphanedAssemblies, UpdateEnergySources},
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
#[error(code = 12)]
const ESenderCannotAccessCharacter: vector<u8> = b"Address cannot access Character";

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
    energy_source_id: Option<ID>,
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
    let storage_unit_id = object::id(storage_unit);
    assert!(access::is_authorized(owner_cap, storage_unit_id), EAssemblyNotAuthorized);
    assert!(option::is_some(&storage_unit.energy_source_id), ENetworkNodeMismatch);
    assert!(
        *option::borrow(&storage_unit.energy_source_id) == object::id(network_node),
        ENetworkNodeMismatch,
    );
    reserve_energy(storage_unit, network_node, energy_config);

    storage_unit.status.online(storage_unit_id, storage_unit.key);
}

public fun offline(
    storage_unit: &mut StorageUnit,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    owner_cap: &OwnerCap<StorageUnit>,
) {
    let storage_unit_id = object::id(storage_unit);
    assert!(access::is_authorized(owner_cap, storage_unit_id), EAssemblyNotAuthorized);

    // Verify network node matches the storage unit's energy source
    assert!(option::is_some(&storage_unit.energy_source_id), ENetworkNodeMismatch);
    assert!(
        *option::borrow(&storage_unit.energy_source_id) == object::id(network_node),
        ENetworkNodeMismatch,
    );
    release_energy(storage_unit, network_node, energy_config);

    storage_unit.status.offline(storage_unit_id, storage_unit.key);
}

/// Bridges items from chain to game inventory
public fun chain_item_to_game_inventory<T: key>(
    storage_unit: &mut StorageUnit,
    server_registry: &ServerAddressRegistry,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    type_id: u64,
    quantity: u32,
    location_proof: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(character.character_address() == ctx.sender(), ESenderCannotAccessCharacter);
    let storage_unit_id = object::id(storage_unit);
    check_inventory_authorization(owner_cap, storage_unit, character.id());
    assert!(storage_unit.status.is_online(), ENotOnline);

    let owner_cap_id = object::id(owner_cap);
    let inventory = df::borrow_mut<ID, Inventory>(
        &mut storage_unit.id,
        owner_cap_id,
    );
    inventory.burn_items_with_proof(
        storage_unit_id,
        storage_unit.key,
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
    let storage_unit_id = object::id(storage_unit);
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
    inventory.deposit_item(
        storage_unit_id,
        storage_unit.key,
        character,
        item,
    );
}

public fun withdraw_item<Auth: drop>(
    storage_unit: &mut StorageUnit,
    character: &Character,
    _: Auth,
    type_id: u64,
    _: &mut TxContext,
): Item {
    let storage_unit_id = object::id(storage_unit);
    assert!(
        storage_unit.extension.contains(&type_name::with_defining_ids<Auth>()),
        EExtensionNotAuthorized,
    );
    let inventory = df::borrow_mut<ID, Inventory>(
        &mut storage_unit.id,
        storage_unit.owner_cap_id,
    );

    inventory.withdraw_item(
        storage_unit_id,
        storage_unit.key,
        character,
        type_id,
    )
}

public fun deposit_by_owner<T: key>(
    storage_unit: &mut StorageUnit,
    item: Item,
    server_registry: &ServerAddressRegistry,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    proximity_proof: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(character.character_address() == ctx.sender(), ESenderCannotAccessCharacter);
    let storage_unit_id = object::id(storage_unit);
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

    inventory.deposit_item(
        storage_unit_id,
        storage_unit.key,
        character,
        item,
    );
}

public fun withdraw_by_owner<T: key>(
    storage_unit: &mut StorageUnit,
    server_registry: &ServerAddressRegistry,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    type_id: u64,
    proximity_proof: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
): Item {
    assert!(character.character_address() == ctx.sender(), ESenderCannotAccessCharacter);
    let storage_unit_id = object::id(storage_unit);
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

    inventory.withdraw_item(
        storage_unit_id,
        storage_unit.key,
        character,
        type_id,
    )
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

/// Returns the storage unit's energy source (network node) ID if set
public fun energy_source_id(storage_unit: &StorageUnit): &Option<ID> {
    &storage_unit.energy_source_id
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

    // Create owner cap and transfer to Character object
    let owner_cap = access::create_owner_cap_by_id<StorageUnit>(admin_cap, assembly_id, ctx);
    let owner_cap_id = object::id(&owner_cap);

    let mut storage_unit = StorageUnit {
        id: assembly_uid,
        key: storage_unit_key,
        owner_cap_id,
        type_id: type_id,
        status: status::anchor(assembly_id, storage_unit_key),
        location: location::attach(location_hash),
        inventory_keys: vector[],
        energy_source_id: option::some(network_node_id),
        metadata: std::option::some(
            metadata::create_metadata(
                assembly_id,
                storage_unit_key,
                b"".to_string(),
                b"".to_string(),
                b"".to_string(),
            ),
        ),
        extension: option::none(),
    };

    access::transfer_owner_cap(owner_cap, object::id_address(character));

    network_node.connect_assembly(assembly_id);

    let inventory = inventory::create(
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
    storage_unit.energy_source_id = option::some(nwn_id);
}

/// Updates the storage unit's energy source and removes it from the UpdateEnergySources hot potato.
/// Must be called for each storage unit in the hot potato returned by connect_assemblies.
public fun update_energy_source_connected_storage_unit(
    storage_unit: &mut StorageUnit,
    mut update_energy_sources: UpdateEnergySources,
    network_node: &NetworkNode,
    _: &AdminCap,
): UpdateEnergySources {
    if (update_energy_sources.update_energy_sources_ids_length() > 0) {
        let storage_unit_id = object::id(storage_unit);
        let found = update_energy_sources.remove_update_energy_sources_assembly_id(
            storage_unit_id,
        );
        if (found) {
            assert!(!storage_unit.status.is_online(), EStorageUnitInvalidState);
            storage_unit.energy_source_id = option::some(object::id(network_node));
        };
    };
    update_energy_sources
}

//  TODO : Can we generalise this function for all assembly
/// Brings a connected storage unit offline and removes it from the hot potato
/// Must be called for each storage unit in the hot potato list
/// Returns the updated hot potato with the processed storage unit removed
/// After all storage units are processed, call destroy_offline_assemblies to consume the hot potato
/// Used for nwn.offline() flow; keeps the energy source so the storage unit can go online again with the same NWN.
public fun offline_connected_storage_unit(
    storage_unit: &mut StorageUnit,
    mut offline_assemblies: OfflineAssemblies,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
): OfflineAssemblies {
    if (offline_assemblies.ids_length() > 0) {
        let storage_unit_id = object::id(storage_unit);
        let found = offline_assemblies.remove_assembly_id(storage_unit_id);
        if (found) {
            bring_offline_and_release_energy(
                storage_unit,
                storage_unit_id,
                network_node,
                energy_config,
            );
        }
    };
    offline_assemblies
}

/// Brings a connected storage unit offline, releases energy, clears energy source, and removes it from the hot potato
/// Must be called for each storage unit in the hot potato returned by nwn.unanchor()
/// Returns the updated HandleOrphanedAssemblies; after all are processed, call destroy_network_node with it
public fun offline_orphaned_storage_unit(
    storage_unit: &mut StorageUnit,
    mut orphaned_assemblies: HandleOrphanedAssemblies,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
): HandleOrphanedAssemblies {
    if (orphaned_assemblies.orphaned_assemblies_length() > 0) {
        let storage_unit_id = object::id(storage_unit);
        let found = orphaned_assemblies.remove_orphaned_assembly_id(storage_unit_id);
        if (found) {
            bring_offline_and_release_energy(
                storage_unit,
                storage_unit_id,
                network_node,
                energy_config,
            );
            storage_unit.energy_source_id = option::none();
        }
    };
    orphaned_assemblies
}

// On unanchor the storage unit is scooped back into inventory in game
// So we burn the items and delete the object
public fun unanchor(
    storage_unit: StorageUnit,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    _: &AdminCap,
) {
    let StorageUnit {
        mut id,
        key,
        status,
        location,
        inventory_keys,
        metadata,
        energy_source_id,
        type_id,
        ..,
    } = storage_unit;

    assert!(option::is_some(&energy_source_id), ENetworkNodeMismatch);
    assert!(*option::borrow(&energy_source_id) == object::id(network_node), ENetworkNodeMismatch);

    // Release energy if storage unit is online
    if (status.is_online()) {
        release_energy_by_type(network_node, energy_config, type_id);
    };

    // Disconnect storage unit from network node
    let storage_unit_id = object::uid_to_inner(&id);
    network_node.disconnect_assembly(storage_unit_id);

    status.unanchor(storage_unit_id, key);
    location.remove();

    // loop through inventory_keys
    inventory_keys.destroy!(
        |inventory_key| df::remove<ID, Inventory>(&mut id, inventory_key).delete(
            storage_unit_id,
            key,
        ),
    );
    metadata.do!(|metadata| metadata.delete());
    let _ = option::destroy_with_default(energy_source_id, object::id(network_node));
    id.delete();
}

public fun unanchor_orphan(storage_unit: StorageUnit, _: &AdminCap) {
    let StorageUnit {
        mut id,
        key,
        status,
        location,
        inventory_keys,
        metadata,
        energy_source_id,
        ..,
    } = storage_unit;

    location.remove();
    let storage_unit_id = object::uid_to_inner(&id);
    inventory_keys.destroy!(
        |inventory_key| df::remove<ID, Inventory>(&mut id, inventory_key).delete(
            storage_unit_id,
            key,
        ),
    );
    status.unanchor(storage_unit_id, key);
    metadata.do!(|metadata| metadata.delete());
    option::destroy_none(energy_source_id);

    id.delete();
}

/// Bridges items from game to chain inventory
public fun game_item_to_chain_inventory<T: key>(
    storage_unit: &mut StorageUnit,
    admin_acl: &AdminACL,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    item_id: u64,
    type_id: u64,
    volume: u64,
    quantity: u32,
    ctx: &mut TxContext,
) {
    assert!(character.character_address() == ctx.sender(), ESenderCannotAccessCharacter);
    let storage_unit_id = object::id(storage_unit);
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
        let inventory = inventory::create(owner_inv.max_capacity());

        storage_unit.inventory_keys.push_back(owner_cap_id);
        df::add(&mut storage_unit.id, owner_cap_id, inventory);
    };

    let inventory = df::borrow_mut<ID, Inventory>(
        &mut storage_unit.id,
        owner_cap_id,
    );
    inventory.mint_items(
        storage_unit_id,
        storage_unit.key,
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
fun bring_offline_and_release_energy(
    storage_unit: &mut StorageUnit,
    storage_unit_id: ID,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
) {
    if (storage_unit.status.is_online()) {
        storage_unit.status.offline(storage_unit_id, storage_unit.key);
        release_energy(storage_unit, network_node, energy_config);
    };
}

fun reserve_energy(
    storage_unit: &StorageUnit,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
) {
    let network_node_id = object::id(network_node);
    network_node
        .borrow_energy_source()
        .reserve_energy(
            network_node_id,
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
    let network_node_id = object::id(network_node);
    network_node
        .borrow_energy_source()
        .release_energy(
            network_node_id,
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
    character: &Character,
    owner_cap: &OwnerCap<T>,
    type_id: u64,
    quantity: u32,
    location_proof: vector<u8>,
    ctx: &mut TxContext,
) {
    assert!(character.character_address() == ctx.sender(), ESenderCannotAccessCharacter);
    let storage_unit_id = object::id(storage_unit);
    let owner_cap_id = object::id(owner_cap);
    check_inventory_authorization(owner_cap, storage_unit, character.id());
    assert!(storage_unit.status.is_online(), ENotOnline);

    let inventory = df::borrow_mut<ID, Inventory>(&mut storage_unit.id, owner_cap_id);
    inventory.burn_items_with_proof_test(
        storage_unit_id,
        storage_unit.key,
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
    character: &Character,
    owner_cap: &OwnerCap<T>,
    item_id: u64,
    type_id: u64,
    volume: u64,
    quantity: u32,
    ctx: &mut TxContext,
) {
    assert!(character.character_address() == ctx.sender(), ESenderCannotAccessCharacter);
    let storage_unit_id = object::id(storage_unit);
    let owner_cap_id = object::id(owner_cap);
    assert!(storage_unit.status.is_online(), ENotOnline);
    check_inventory_authorization(owner_cap, storage_unit, character.id());

    // create a ephemeral inventory if it does not exists for a character
    if (!df::exists_(&storage_unit.id, owner_cap_id)) {
        let owner_inv = df::borrow<ID, Inventory>(
            &storage_unit.id,
            storage_unit.owner_cap_id,
        );
        let inventory = inventory::create(owner_inv.max_capacity());

        storage_unit.inventory_keys.push_back(owner_cap_id);
        df::add(&mut storage_unit.id, owner_cap_id, inventory);
    };

    let inventory = df::borrow_mut<ID, Inventory>(
        &mut storage_unit.id,
        owner_cap_id,
    );
    inventory.mint_items(
        storage_unit_id,
        storage_unit.key,
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
