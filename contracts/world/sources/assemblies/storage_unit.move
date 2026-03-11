/// This module handles the functionality of the in-game Storage Unit Assembly
///
/// The Storage Unit is a programmable, on-chain storage structure.
/// It can allow players to store, withdraw, and manage items under rules they design themselves.
/// The behaviour of a Storage Unit can be customized by registering a custom contract
/// using the typed witness pattern. https://github.com/evefrontier/world-contracts/blob/main/docs/architechture.md#layer-3-player-extensions-moddability
///
/// Storage Units support three access modes to enable player-to-player interactions:
///
/// 1. **Extension-based access** (Main inventory):
///    - Functions: `deposit_item<Auth>`, `withdraw_item<Auth>`
///    - Allows 3rd party contracts to handle inventory operations on behalf of the owner
///
/// 2. **Extension-to-owned deposit**:
///    - Function: `deposit_to_owned<Auth>`
///    - Allows extensions to push items into a player's owned inventory
///    - Target is validated as an existing Character (owner_cap_id derived on-chain)
///    - Target player does NOT need to be the transaction sender
///    - Source inventory depends on extension logic (main or owned)
///    - Enables async trading, guild hangars, automated rewards
///
/// 3. **Owner-direct access** (Owned inventory)
///    - Functions: `deposit_by_owner`, `withdraw_by_owner`
///    - Allows the owner to deposit/withdraw from their owned inventory
///    - Requires OwnerCap + sender == character address
///
/// Future pattern: Storage Units (extension-controlled), Ships (owner-controlled)
module world::storage_unit;

use std::{bcs, string::String, type_name::{Self, TypeName}};
use sui::{address, clock::Clock, derived_object, dynamic_field as df, event, hash};
use world::{
    access::{Self, OwnerCap, ServerAddressRegistry, AdminACL},
    character::Character,
    energy::EnergyConfig,
    extension_freeze,
    in_game_id::{Self, TenantItemId},
    inventory::{Self, Inventory, Item},
    location::{Self, Location, LocationRegistry},
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
const ENetworkNodeMismatch: vector<u8> =
    b"Provided network node does not match the storage unit's configured energy source";
#[error(code = 9)]
const EStorageUnitInvalidState: vector<u8> = b"Storage Unit should be offline";
#[error(code = 10)]
const ESenderCannotAccessCharacter: vector<u8> = b"Address cannot access Character";
#[error(code = 11)]
const EItemParentMismatch: vector<u8> = b"Item was not withdrawn from this storage unit";
#[error(code = 12)]
const EMetadataNotSet: vector<u8> = b"Metadata not set on assembly";
#[error(code = 13)]
const EExtensionConfigFrozen: vector<u8> = b"Extension configuration is frozen";
#[error(code = 14)]
const EExtensionNotConfigured: vector<u8> = b"Extension must be configured before freezing";
#[error(code = 15)]
const EOpenStorageNotInitialized: vector<u8> =
    b"Open storage has not been initialized (deposit first)";

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

public struct ExtensionAuthorizedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    extension_type: TypeName,
    previous_extension: Option<TypeName>,
    owner_cap_id: ID,
}

// === Public Functions ===
public fun authorize_extension<Auth: drop>(
    storage_unit: &mut StorageUnit,
    owner_cap: &OwnerCap<StorageUnit>,
) {
    let storage_unit_id = object::id(storage_unit);
    assert!(access::is_authorized(owner_cap, storage_unit_id), EAssemblyNotAuthorized);
    assert!(!extension_freeze::is_extension_frozen(&storage_unit.id), EExtensionConfigFrozen);
    let previous_extension = storage_unit.extension;
    storage_unit.extension.swap_or_fill(type_name::with_defining_ids<Auth>());
    event::emit(ExtensionAuthorizedEvent {
        assembly_id: storage_unit_id,
        assembly_key: storage_unit.key,
        extension_type: type_name::with_defining_ids<Auth>(),
        previous_extension,
        owner_cap_id: object::id(owner_cap),
    });
}

/// Freezes the storage unit's extension configuration so the owner can no longer change it (builds user trust).
/// Requires an extension to be configured. One-time; cannot be undone.
public fun freeze_extension_config(
    storage_unit: &mut StorageUnit,
    owner_cap: &OwnerCap<StorageUnit>,
) {
    let storage_unit_id = object::id(storage_unit);
    assert!(access::is_authorized(owner_cap, storage_unit_id), EAssemblyNotAuthorized);
    assert!(option::is_some(&storage_unit.extension), EExtensionNotConfigured);
    assert!(!extension_freeze::is_extension_frozen(&storage_unit.id), EExtensionConfigFrozen);
    extension_freeze::freeze_extension_config(&mut storage_unit.id, storage_unit_id);
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

// TODO: add additional check for proximity proof
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
    assert!(inventory::parent_id(&item) == storage_unit_id, EItemParentMismatch);
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
    quantity: u32,
    ctx: &mut TxContext,
): Item {
    let storage_unit_id = object::id(storage_unit);
    assert!(
        storage_unit.extension.contains(&type_name::with_defining_ids<Auth>()),
        EExtensionNotAuthorized,
    );
    assert!(storage_unit.status.is_online(), ENotOnline);

    let inventory = df::borrow_mut<ID, Inventory>(
        &mut storage_unit.id,
        storage_unit.owner_cap_id,
    );

    inventory.withdraw_item(
        storage_unit_id,
        storage_unit.key,
        character,
        type_id,
        quantity,
        storage_unit.location.hash(),
        ctx,
    )
}

/// Extension-only deposit into open storage (contract-controlled).
/// Owners and players can withdraw only via `withdraw_from_open_inventory`, i.e. through extension logic, not directly.
/// Creates the open inventory on first use. Only the registered extension can call this.
public fun deposit_to_open_inventory<Auth: drop>(
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
    assert!(inventory::parent_id(&item) == storage_unit_id, EItemParentMismatch);

    ensure_open_inventory(storage_unit);

    let key = open_storage_key(storage_unit);
    let inventory = df::borrow_mut<ID, Inventory>(&mut storage_unit.id, key);
    inventory.deposit_item(
        storage_unit_id,
        storage_unit.key,
        character,
        item,
    );
}

/// Extension-only withdraw from open storage. Only the registered extension can call this.
/// Aborts with EOpenStorageNotInitialized if open storage has never been used (no prior deposit_to_open_inventory).
public fun withdraw_from_open_inventory<Auth: drop>(
    storage_unit: &mut StorageUnit,
    character: &Character,
    _: Auth,
    type_id: u64,
    quantity: u32,
    ctx: &mut TxContext,
): Item {
    let storage_unit_id = object::id(storage_unit);
    assert!(
        storage_unit.extension.contains(&type_name::with_defining_ids<Auth>()),
        EExtensionNotAuthorized,
    );
    assert!(storage_unit.status.is_online(), ENotOnline);
    let key = open_storage_key(storage_unit);
    assert!(df::exists_(&storage_unit.id, key), EOpenStorageNotInitialized);

    let inventory = df::borrow_mut<ID, Inventory>(&mut storage_unit.id, key);
    inventory.withdraw_item(
        storage_unit_id,
        storage_unit.key,
        character,
        type_id,
        quantity,
        storage_unit.location.hash(),
        ctx,
    )
}

/// Extension-authorized deposit into a player's owned inventory.
/// Unlike `deposit_by_owner`, the recipient (the `character` argument) does NOT need to be
/// the transaction sender. The recipient's owned inventory is derived from
/// `character.owner_cap_id()`, ensuring the character is a valid, existing Character.
/// Creates the owned inventory if it doesn't exist yet.
public fun deposit_to_owned<Auth: drop>(
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
    assert!(item.tenant() == storage_unit.key.tenant(), ETenantMismatch);
    assert!(character.tenant() == storage_unit.key.tenant(), ETenantMismatch);
    assert!(item.parent_id() == storage_unit_id, EItemParentMismatch);

    let owner_cap_id = character.owner_cap_id();

    if (!df::exists_(&storage_unit.id, owner_cap_id)) {
        let owner_inv = df::borrow<ID, Inventory>(
            &storage_unit.id,
            storage_unit.owner_cap_id,
        );
        let owned_inventory = inventory::create(owner_inv.max_capacity());
        storage_unit.inventory_keys.push_back(owner_cap_id);
        df::add(&mut storage_unit.id, owner_cap_id, owned_inventory);
    };

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

public fun deposit_by_owner<T: key>(
    storage_unit: &mut StorageUnit,
    item: Item,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    ctx: &mut TxContext,
) {
    assert!(character.character_address() == ctx.sender(), ESenderCannotAccessCharacter);
    let storage_unit_id = object::id(storage_unit);
    let owner_cap_id = object::id(owner_cap);
    assert!(storage_unit.status.is_online(), ENotOnline);
    check_inventory_authorization(owner_cap, storage_unit, character.id());
    assert!(inventory::tenant(&item) == storage_unit.key.tenant(), ETenantMismatch);
    assert!(inventory::parent_id(&item) == storage_unit_id, EItemParentMismatch);

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
    character: &Character,
    owner_cap: &OwnerCap<T>,
    type_id: u64,
    quantity: u32,
    ctx: &mut TxContext,
): Item {
    assert!(character.character_address() == ctx.sender(), ESenderCannotAccessCharacter);
    let storage_unit_id = object::id(storage_unit);
    let owner_cap_id = object::id(owner_cap);
    assert!(storage_unit.status.is_online(), ENotOnline);
    check_inventory_authorization(owner_cap, storage_unit, character.id());

    let inventory = df::borrow_mut<ID, Inventory>(
        &mut storage_unit.id,
        owner_cap_id,
    );

    inventory.withdraw_item(
        storage_unit_id,
        storage_unit.key,
        character,
        type_id,
        quantity,
        storage_unit.location.hash(),
        ctx,
    )
}

public fun update_metadata_name(
    storage_unit: &mut StorageUnit,
    owner_cap: &OwnerCap<StorageUnit>,
    name: String,
) {
    assert!(access::is_authorized(owner_cap, object::id(storage_unit)), EAssemblyNotAuthorized);
    assert!(option::is_some(&storage_unit.metadata), EMetadataNotSet);
    let metadata = option::borrow_mut(&mut storage_unit.metadata);
    metadata.update_name(storage_unit.key, name);
}

public fun update_metadata_description(
    storage_unit: &mut StorageUnit,
    owner_cap: &OwnerCap<StorageUnit>,
    description: String,
) {
    assert!(access::is_authorized(owner_cap, object::id(storage_unit)), EAssemblyNotAuthorized);
    assert!(option::is_some(&storage_unit.metadata), EMetadataNotSet);
    let metadata = option::borrow_mut(&mut storage_unit.metadata);
    metadata.update_description(storage_unit.key, description);
}

public fun update_metadata_url(
    storage_unit: &mut StorageUnit,
    owner_cap: &OwnerCap<StorageUnit>,
    url: String,
) {
    assert!(access::is_authorized(owner_cap, object::id(storage_unit)), EAssemblyNotAuthorized);
    assert!(option::is_some(&storage_unit.metadata), EMetadataNotSet);
    let metadata = option::borrow_mut(&mut storage_unit.metadata);
    metadata.update_url(storage_unit.key, url);
}

/// Reveals plain-text location (solarsystem, x, y, z) for this storage unit. Admin ACL only. Optional; enables dapps (e.g. route maps).
/// Temporary: use until the offchain location reveal service is ready.
public fun reveal_location(
    storage_unit: &StorageUnit,
    registry: &mut LocationRegistry,
    admin_acl: &AdminACL,
    solarsystem: u64,
    x: String,
    y: String,
    z: String,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    location::reveal_location(
        registry,
        object::id(storage_unit),
        storage_unit.key,
        storage_unit.type_id,
        storage_unit.owner_cap_id,
        location::hash(&storage_unit.location),
        solarsystem,
        x,
        y,
        z,
    );
}

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

/// Returns true if the storage unit's extension configuration is frozen (owner cannot change extension).
public fun is_extension_frozen(storage_unit: &StorageUnit): bool {
    extension_freeze::is_extension_frozen(&storage_unit.id)
}

/// Returns the dynamic field key for open storage (contract-only; no owner or player control).
/// Clients can use this to identify the open slot in inventory_keys and display it separately.
public fun open_storage_key(storage_unit: &StorageUnit): ID {
    open_storage_key_from_id(object::id(storage_unit))
}

/// Returns true if this storage unit has open storage (always true for SSUs anchored with open storage).
public fun has_open_storage(storage_unit: &StorageUnit): bool {
    df::exists_(&storage_unit.id, open_storage_key(storage_unit))
}

// === Admin Functions ===
public fun anchor(
    registry: &mut ObjectRegistry,
    network_node: &mut NetworkNode,
    character: &Character,
    admin_acl: &AdminACL,
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
    let owner_cap = access::create_owner_cap_by_id<StorageUnit>(assembly_id, admin_acl, ctx);
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

    let inventory = inventory::create(max_capacity);
    storage_unit.inventory_keys.push_back(owner_cap_id);
    df::add(&mut storage_unit.id, owner_cap_id, inventory);

    // Future: we could set open-inventory max_capacity separately from owner ephemeral/owned (EVM version had different limits).
    // If we do, we must change how we bootstrap max_capacity in ensure_open_inventory for existing SSUs (currently uses owner ephemeral capacity, same as deposit_to_owned).
    let open_inv_key = open_storage_key_from_id(assembly_id);
    let open_inventory = inventory::create(max_capacity);
    storage_unit.inventory_keys.push_back(open_inv_key);
    df::add(&mut storage_unit.id, open_inv_key, open_inventory);

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

public fun share_storage_unit(storage_unit: StorageUnit, admin_acl: &AdminACL, ctx: &TxContext) {
    admin_acl.verify_sponsor(ctx);
    transfer::share_object(storage_unit);
}

public fun update_energy_source(
    storage_unit: &mut StorageUnit,
    network_node: &mut NetworkNode,
    admin_acl: &AdminACL,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
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
): UpdateEnergySources {
    if (update_energy_sources.update_energy_sources_ids_length() > 0) {
        let storage_unit_id = object::id(storage_unit);
        let found = update_energy_sources.remove_energy_sources_assembly_id(
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
    admin_acl: &AdminACL,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
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
    extension_freeze::remove_frozen_marker_if_present(&mut id);
    metadata.do!(|metadata| metadata.delete());
    let _ = option::destroy_with_default(energy_source_id, object::id(network_node));
    id.delete();
}

public fun unanchor_orphan(storage_unit: StorageUnit, admin_acl: &AdminACL, ctx: &TxContext) {
    admin_acl.verify_sponsor(ctx);
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
    extension_freeze::remove_frozen_marker_if_present(&mut id);
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
    admin_acl.verify_sponsor(ctx);
    let storage_unit_id = object::id(storage_unit);
    let owner_cap_id = object::id(owner_cap);
    assert!(storage_unit.status.is_online(), ENotOnline);
    check_inventory_authorization(owner_cap, storage_unit, character.id());

    // create an owned inventory if it does not exist for a character
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
    )
}

// === Private Functions ===
/// Deterministic key for open inventory derived from storage unit id (no collision with owner_cap_id).
fun open_storage_key_from_id(storage_unit_id: ID): ID {
    let mut storage_unit_id_bytes = bcs::to_bytes(&storage_unit_id);
    vector::append(&mut storage_unit_id_bytes, b"open_inventory");
    let digest = hash::blake2b256(&storage_unit_id_bytes);
    let addr = address::from_bytes(digest);
    object::id_from_address(addr)
}

/// Creates the open inventory if it does not exist (backward compat for SSUs anchored before open storage existed).
/// Bootstraps max_capacity from owner ephemeral (same as deposit_to_owned).
/// TODO: If we later decouple native vs ephemeral capacity, this bootstrap must be updated.
fun ensure_open_inventory(storage_unit: &mut StorageUnit) {
    let key = open_storage_key(storage_unit);
    if (!df::exists_(&storage_unit.id, key)) {
        let owner_inv = df::borrow<ID, Inventory>(
            &storage_unit.id,
            storage_unit.owner_cap_id,
        );
        let open_inventory = inventory::create(owner_inv.max_capacity());
        storage_unit.inventory_keys.push_back(key);
        df::add(&mut storage_unit.id, key, open_inventory);
    };
}

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

    // create an owned inventory if it does not exist for a character
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
    )
}
