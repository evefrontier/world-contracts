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
    network_node::{NetworkNode, OfflineAssemblies},
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

// === Structs ===
// TODO: find an elegant way to decouple the common fields across all structs
public struct Assembly has key {
    id: UID,
    key: TenantItemId,
    owner_cap_id: ID,
    type_id: u64,
    status: AssemblyStatus,
    location: Location,
    energy_source_id: ID,
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
    assert!(access::is_authorized(owner_cap, object::id(assembly)), EAssemblyNotAuthorized);
    assert!(assembly.energy_source_id == object::id(network_node), ENetworkNodeDoesNotExist);
    reserve_energy(assembly, network_node, energy_config);

    assembly.status.online();
}

public fun offline(
    assembly: &mut Assembly,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    owner_cap: &OwnerCap<Assembly>,
) {
    assert!(access::is_authorized(owner_cap, object::id(assembly)), EAssemblyNotAuthorized);

    // Verify network node matches the assembly's energy source
    assert!(assembly.energy_source_id == object::id(network_node), ENetworkNodeDoesNotExist);
    release_energy(assembly, network_node, energy_config);

    assembly.status.offline();
}

// === View Functions ===
public fun status(assembly: &Assembly): &AssemblyStatus {
    &assembly.status
}

public fun owner_cap_id(assembly: &Assembly): ID {
    assembly.owner_cap_id
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
    let owner_cap_id = access::create_and_transfer_owner_cap<Assembly>(
        admin_cap,
        assembly_id,
        character.character_address(),
        ctx,
    );

    let assembly = Assembly {
        id: assembly_uid,
        key: assembly_key,
        owner_cap_id,
        type_id,
        status: status::anchor(assembly_id, type_id, item_id),
        location: location::attach(assembly_id, location_hash),
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
    };

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
    assembly.energy_source_id = nwn_id;
}

/// Brings a connected assembly offline and removes it from the hot potato
/// Must be called for each assembly in the hot potato list
/// Returns the updated hot potato with the processed assembly removed
/// After all assemblies are processed, call destroy_offline_assemblies to consume the hot potato
/// The hot potato itself serves as authorization since it can only be obtained from capped functions
public fun offline_connected_assembly(
    assembly: &mut Assembly,
    mut offline_assemblies: OfflineAssemblies,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
): OfflineAssemblies {
    if (offline_assemblies.ids_length() > 0) {
        let assembly_id = object::id(assembly);

        // Remove the assembly ID from the hot potato using package function
        let found = offline_assemblies.remove_assembly_id(assembly_id);

        if (found) {
            // Bring the assembly offline if it's online and release energy
            if (assembly.status.is_online()) {
                assembly.status.offline();
                release_energy(assembly, network_node, energy_config);
            };
        }
    };
    offline_assemblies
}

public fun unanchor(
    assembly: Assembly,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    _: &AdminCap,
) {
    let Assembly {
        id,
        status,
        location,
        metadata,
        energy_source_id,
        type_id,
        ..,
    } = assembly;

    assert!(energy_source_id == object::id(network_node), ENetworkNodeDoesNotExist);

    // Release energy if assembly is online
    if (status.is_online()) {
        release_energy_by_type(network_node, energy_config, type_id);
    };

    // Disconnect assembly from network node
    let assembly_id = object::uid_to_inner(&id);
    network_node.disconnect_assembly(assembly_id);

    location.remove();
    status.unanchor();
    metadata.do!(|metadata| metadata.delete());

    // deleting doesnt mean the object id can be reclaimed.
    // however right now according to game design you cannot anchor after unanchor so its safe
    id.delete();
    // In future we can do
    // derived_object::reclaim(&mut registry, id);
}

// === Private Functions ===
/// Reserves energy from the network node for the assembly
fun reserve_energy(
    assembly: &Assembly,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
) {
    network_node
        .borrow_energy_source()
        .reserve_energy(
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
    network_node
        .borrow_energy_source()
        .release_energy(
            energy_config,
            type_id,
        );
}

#[test_only]
public fun location(assembly: &Assembly): &Location {
    &assembly.location
}
