/// This module handles all the operations for generalized assemblies
/// Basic operations are anchor, unanchor, online, offline and destroy
module world::assembly;

use sui::{derived_object, event};
use world::{
    access::{Self, AdminCap, OwnerCap},
    character::Character,
    energy::EnergyConfig,
    in_game_id::{Self, TenantItemId},
    location::{Self, Location},
    metadata::{Self, Metadata},
    network_node::{NetworkNode, OfflineAssemblies, HandleOrphanedAssemblies, UpdateEnergySources},
    object_registry::ObjectRegistry,
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
#[error(code = 4)]
const ENetworkNodeDoesNotExist: vector<u8> =
    b"Provided network node does not match the assembly's configured energy source";
#[error(code = 5)]
const EAssemblyOnline: vector<u8> = b"Assembly should be offline";
#[error(code = 6)]
const EAssemblyHasEnergySource: vector<u8> = b"Assembly has an energy source";

// === Structs ===
// TODO: find an elegant way to decouple the common fields across all structs
public struct Assembly has key {
    id: UID,
    key: TenantItemId,
    owner_cap_id: ID,
    type_id: u64,
    status: AssemblyStatus,
    location: Location,
    energy_source_id: Option<ID>,
    metadata: Option<Metadata>,
}

// === Events ===
public struct AssemblyCreatedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    owner_cap_id: ID,
    type_id: u64,
}

// === Public Functions ===
public fun online(
    assembly: &mut Assembly,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    owner_cap: &OwnerCap<Assembly>,
) {
    let assembly_id = object::id(assembly);
    assert!(access::is_authorized(owner_cap, assembly_id), EAssemblyNotAuthorized);
    assert!(option::is_some(&assembly.energy_source_id), ENetworkNodeDoesNotExist);
    assert!(
        *option::borrow(&assembly.energy_source_id) == object::id(network_node),
        ENetworkNodeDoesNotExist,
    );
    reserve_energy(assembly, network_node, energy_config);

    assembly.status.online(assembly_id, assembly.key);
}

public fun offline(
    assembly: &mut Assembly,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    owner_cap: &OwnerCap<Assembly>,
) {
    let assembly_id = object::id(assembly);
    assert!(access::is_authorized(owner_cap, assembly_id), EAssemblyNotAuthorized);

    // Verify network node matches the assembly's energy source
    assert!(option::is_some(&assembly.energy_source_id), ENetworkNodeDoesNotExist);
    assert!(
        *option::borrow(&assembly.energy_source_id) == object::id(network_node),
        ENetworkNodeDoesNotExist,
    );
    release_energy(assembly, network_node, energy_config);

    assembly.status.offline(assembly_id, assembly.key);
}

// === View Functions ===
public fun status(assembly: &Assembly): &AssemblyStatus {
    &assembly.status
}

public fun owner_cap_id(assembly: &Assembly): ID {
    assembly.owner_cap_id
}

/// Returns the assembly's energy source (network node) ID if set
public fun energy_source_id(assembly: &Assembly): &Option<ID> {
    &assembly.energy_source_id
}

// === Admin Functions ===
public fun anchor(
    registry: &mut ObjectRegistry,
    network_node: &mut NetworkNode,
    character: &Character,
    admin_cap: &AdminCap,
    item_id: u64,
    type_id: u64,
    location_hash: vector<u8>,
    ctx: &mut TxContext,
): Assembly {
    assert!(type_id != 0, EAssemblyTypeIdEmpty);
    assert!(item_id != 0, EAssemblyItemIdEmpty);

    let tenant = character.tenant();
    // key to derive assembly object id
    let assembly_key = in_game_id::create_key(item_id, tenant);
    assert!(!registry.object_exists(assembly_key), EAssemblyAlreadyExists);

    let assembly_uid = derived_object::claim(registry.borrow_registry_id(), assembly_key);
    let assembly_id = object::uid_to_inner(&assembly_uid);
    let network_node_id = object::id(network_node);

    // Create owner cap first with just the ID
    let owner_cap = access::create_owner_cap_by_id<Assembly>(admin_cap, assembly_id, ctx);
    let owner_cap_id = object::id(&owner_cap);

    let assembly = Assembly {
        id: assembly_uid,
        key: assembly_key,
        owner_cap_id,
        type_id,
        status: status::anchor(assembly_id, assembly_key),
        location: location::attach(location_hash),
        energy_source_id: option::some(network_node_id),
        metadata: std::option::some(
            metadata::create_metadata(
                assembly_id,
                assembly_key,
                b"".to_string(),
                b"".to_string(),
                b"".to_string(),
            ),
        ),
    };

    access::transfer_owner_cap(owner_cap, object::id_address(character));

    // Connect assembly to network node
    network_node.connect_assembly(assembly_id);

    event::emit(AssemblyCreatedEvent {
        assembly_id,
        assembly_key,
        owner_cap_id,
        type_id,
    });
    assembly
}

public fun share_assembly(assembly: Assembly, _: &AdminCap) {
    transfer::share_object(assembly);
}

/// Updates the energy source (network node) for an assembly
public fun update_energy_source(
    assembly: &mut Assembly,
    network_node: &mut NetworkNode,
    _: &AdminCap,
) {
    let assembly_id = object::id(assembly);
    let nwn_id = object::id(network_node);
    assert!(!assembly.status.is_online(), EAssemblyOnline);

    network_node.connect_assembly(assembly_id);
    assembly.energy_source_id = option::some(nwn_id);
}

/// Updates the assembly's energy source and removes it from the UpdateEnergySources hot potato.
/// Must be called for each assembly in the hot potato returned by connect_assemblies.
public fun update_energy_source_connected_assembly(
    assembly: &mut Assembly,
    mut update_energy_sources: UpdateEnergySources,
    network_node: &NetworkNode,
    _: &AdminCap,
): UpdateEnergySources {
    if (update_energy_sources.update_energy_sources_ids_length() > 0) {
        let assembly_id = object::id(assembly);
        let found = update_energy_sources.remove_update_energy_sources_assembly_id(
            assembly_id,
        );
        if (found) {
            assert!(!assembly.status.is_online(), EAssemblyOnline);
            assembly.energy_source_id = option::some(object::id(network_node));
        };
    };
    update_energy_sources
}

/// Brings a connected assembly offline and removes it from the hot potato
/// Must be called for each assembly in the hot potato list
/// Returns the updated hot potato with the processed assembly removed
/// After all assemblies are processed, call destroy_offline_assemblies to consume the hot potato
public fun offline_connected_assembly(
    assembly: &mut Assembly,
    mut offline_assemblies: OfflineAssemblies,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
): OfflineAssemblies {
    if (offline_assemblies.ids_length() > 0) {
        let assembly_id = object::id(assembly);
        let found = offline_assemblies.remove_assembly_id(assembly_id);
        if (found) {
            bring_offline_and_release_energy(assembly, assembly_id, network_node, energy_config);
        }
    };
    offline_assemblies
}

/// Brings a connected assembly offline, releases energy, clears energy source, and removes it from the hot potato
/// Must be called for each assembly in the hot potato returned by nwn.unanchor()
/// Returns the updated HandleOrphanedAssemblies; after all are processed, call destroy_network_node with it
public fun offline_orphaned_assembly(
    assembly: &mut Assembly,
    mut orphaned_assemblies: HandleOrphanedAssemblies,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
): HandleOrphanedAssemblies {
    if (orphaned_assemblies.orphaned_assemblies_length() > 0) {
        let assembly_id = object::id(assembly);
        let found = orphaned_assemblies.remove_orphaned_assembly_id(assembly_id);
        if (found) {
            bring_offline_and_release_energy(assembly, assembly_id, network_node, energy_config);
            assembly.energy_source_id = option::none();
        }
    };
    orphaned_assemblies
}

public fun unanchor(
    assembly: Assembly,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    _: &AdminCap,
) {
    let Assembly {
        id,
        key,
        status,
        location,
        metadata,
        energy_source_id,
        type_id,
        ..,
    } = assembly;

    assert!(option::is_some(&energy_source_id), ENetworkNodeDoesNotExist);
    assert!(
        *option::borrow(&energy_source_id) == object::id(network_node),
        ENetworkNodeDoesNotExist,
    );

    // Release energy if assembly is online
    if (status.is_online()) {
        release_energy_by_type(network_node, energy_config, type_id);
    };

    // Disconnect assembly from network node
    let assembly_id = object::uid_to_inner(&id);
    network_node.disconnect_assembly(assembly_id);

    location.remove();
    status.unanchor(assembly_id, key);
    metadata.do!(|metadata| metadata.delete());
    let _ = option::destroy_with_default(energy_source_id, object::id(network_node));

    // deleting doesnt mean the object id can be reclaimed.
    // however right now according to game design you cannot anchor after unanchor so its safe
    id.delete();
    // In future we can do
    // derived_object::reclaim(&mut registry, id);
}

public fun unanchor_orphan(assembly: Assembly, _: &AdminCap) {
    let Assembly {
        id,
        key,
        status,
        location,
        metadata,
        energy_source_id,
        ..,
    } = assembly;

    // Orphaned assemblies should already be disconnected and offline.
    assert!(option::is_none(&energy_source_id), EAssemblyHasEnergySource);
    assert!(!status.is_online(), EAssemblyOnline);

    location.remove();
    let assembly_id = object::uid_to_inner(&id);
    status.unanchor(assembly_id, key);
    metadata.do!(|metadata| metadata.delete());
    option::destroy_none(energy_source_id);

    id.delete();
}

// === Private Functions ===
/// Brings the assembly offline if online and releases energy to the network node
fun bring_offline_and_release_energy(
    assembly: &mut Assembly,
    assembly_id: ID,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
) {
    if (assembly.status.is_online()) {
        assembly.status.offline(assembly_id, assembly.key);
        release_energy(assembly, network_node, energy_config);
    };
}

/// Reserves energy from the network node for the assembly
fun reserve_energy(
    assembly: &Assembly,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
) {
    let energy_source_id = object::id(network_node);
    network_node
        .borrow_energy_source()
        .reserve_energy(
            energy_source_id,
            energy_config,
            assembly.type_id,
        );
}

/// Releases energy to the network node for the assembly
fun release_energy(
    assembly: &Assembly,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
) {
    release_energy_by_type(network_node, energy_config, assembly.type_id);
}

/// Releases energy to the network node by assembly type
fun release_energy_by_type(
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    type_id: u64,
) {
    let energy_source_id = object::id(network_node);
    network_node
        .borrow_energy_source()
        .release_energy(
            energy_source_id,
            energy_config,
            type_id,
        );
}

#[test_only]
public fun location(assembly: &Assembly): &Location {
    &assembly.location
}
