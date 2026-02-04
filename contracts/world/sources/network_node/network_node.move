/// This module handles the in-game Network Node functionality
///
/// The Network node is an energy source for all the assemblies connected to it
/// It can be fuelled and burn fuel to produce energy in GJ
/// This energy can be used by the assemblies to perform actions like online, bridging items, etc
/// Assemblies have to be connected to a network node to reserve and release energy
///
/// Future: There might be multiple power sources connected together to generate more energy that can be used by assemblies in the base
module world::network_node;

use sui::{clock::Clock, derived_object, event};
use world::{
    access::{Self, OwnerCap, AdminCap, AdminACL},
    character::Character,
    energy::{Self, EnergySource},
    fuel::{Self, FuelConfig, Fuel},
    in_game_id::{Self, TenantItemId},
    location::{Self, Location},
    metadata::{Self, Metadata},
    object_registry::ObjectRegistry,
    status::{Self, AssemblyStatus}
};

// === Errors ===
#[error(code = 0)]
const ENetworkNodeTypeIdEmpty: vector<u8> = b"Network Node TypeId is empty";
#[error(code = 1)]
const ENetworkNodeItemIdEmpty: vector<u8> = b"Network Node ItemId is empty";
#[error(code = 2)]
const ENetworkNodeAlreadyExists: vector<u8> = b"Network Node with this ItemId already exists";
#[error(code = 3)]
const ENetworkNodeNotAuthorized: vector<u8> = b"Network Node access not authorized";
#[error(code = 4)]
const EAssemblyAlreadyConnected: vector<u8> = b"Assembly is already connected to this network node";
#[error(code = 5)]
const EAssemblyNotConnected: vector<u8> = b"Assembly is not connected to this network node";
#[error(code = 6)]
const EAssembliesConnected: vector<u8> = b"Assemblies needs to be disconnected before unanchor";
#[error(code = 7)]
const ENetworkNodeOffline: vector<u8> = b"Network Node is offline";
#[error(code = 8)]
const EUpdateEnergySourcesNotProcessed: vector<u8> =
    b"Energy source must be updated for all connected assemblies";
#[error(code = 9)]
const EOrphanedAssembliesNotOfflined: vector<u8> =
    b"Orphaned assemblies must be offlined before destroying network node";

// === Structs ===
/// Hot potato struct to enforce all connected assemblies are brought offline
public struct OfflineAssemblies {
    assembly_ids: vector<ID>,
}

public struct HandleOrphanedAssemblies {
    assembly_ids: vector<ID>,
}

/// Hot potato struct to enforce energy source is updated for each connected assembly
public struct UpdateEnergySources {
    assembly_ids: vector<ID>,
}

public struct NetworkNode has key {
    id: UID,
    key: TenantItemId,
    owner_cap_id: ID,
    type_id: u64,
    status: AssemblyStatus,
    location: Location,
    fuel: Fuel,
    energy_source: EnergySource,
    metadata: Option<Metadata>,
    connected_assembly_ids: vector<ID>,
}

// === Events ===
public struct NetworkNodeCreatedEvent has copy, drop {
    network_node_id: ID,
    assembly_key: TenantItemId,
    owner_cap_id: ID,
    type_id: u64,
    fuel_max_capacity: u64,
    fuel_burn_rate_in_ms: u64,
    max_energy_production: u64,
}

// === Public Functions ===
public fun deposit_fuel(
    nwn: &mut NetworkNode,
    admin_acl: &AdminACL,
    owner_cap: &OwnerCap<NetworkNode>,
    type_id: u64,
    volume: u64,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let nwn_id = object::id(nwn);
    let nwn_key = nwn.key;
    assert!(access::is_authorized(owner_cap, nwn_id), ENetworkNodeNotAuthorized);
    admin_acl.verify_sponsor(ctx);
    nwn.fuel.deposit(nwn_id, nwn_key, type_id, volume, quantity, clock);
}

public fun withdraw_fuel(
    nwn: &mut NetworkNode,
    admin_acl: &AdminACL,
    owner_cap: &OwnerCap<NetworkNode>,
    quantity: u64,
    ctx: &mut TxContext,
) {
    let nwn_id = object::id(nwn);
    let nwn_key = nwn.key;
    assert!(access::is_authorized(owner_cap, nwn_id), ENetworkNodeNotAuthorized);
    admin_acl.verify_sponsor(ctx);
    nwn.fuel.withdraw(nwn_id, nwn_key, quantity);
}

public fun online(nwn: &mut NetworkNode, owner_cap: &OwnerCap<NetworkNode>, clock: &Clock) {
    let nwn_id = object::id(nwn);
    assert!(access::is_authorized(owner_cap, nwn_id), ENetworkNodeNotAuthorized);
    nwn.fuel.start_burning(nwn_id, nwn.key, clock);
    nwn.energy_source.start_energy_production(nwn_id);
    nwn.status.online(nwn_id, nwn.key);
}

/// Takes the network node offline and returns a hot potato that must be consumed
/// by bringing all connected assemblies offline in the same transaction
public fun offline(
    nwn: &mut NetworkNode,
    fuel_config: &FuelConfig,
    owner_cap: &OwnerCap<NetworkNode>,
    clock: &Clock,
): OfflineAssemblies {
    let nwn_id = object::id(nwn);
    assert!(access::is_authorized(owner_cap, nwn_id), ENetworkNodeNotAuthorized);
    assert!(nwn.status.is_online(), ENetworkNodeOffline);

    // Update fuel first to consume any pending fuel
    nwn.fuel.update(nwn_id, nwn.key, fuel_config, clock);

    if (nwn.fuel.is_burning()) {
        nwn.fuel.stop_burning(nwn_id, nwn.key, fuel_config, clock);
    };

    if (nwn.energy_source.current_energy_production() > 0) {
        nwn.energy_source.stop_energy_production(nwn_id);
    };

    nwn.status.offline(nwn_id, nwn.key);

    OfflineAssemblies {
        assembly_ids: copy_connected_assembly_ids(nwn),
    }
}

// === View Functions ===
/// Returns the list of connected assembly IDs
public fun connected_assemblies(nwn: &NetworkNode): vector<ID> {
    nwn.connected_assembly_ids
}

/// Checks if an assembly is connected to this network node
public fun is_assembly_connected(nwn: &NetworkNode, assembly_id: ID): bool {
    let mut i = 0;
    let len = nwn.connected_assembly_ids.length();
    while (i < len) {
        if (*vector::borrow(&nwn.connected_assembly_ids, i) == assembly_id) {
            return true
        };
        i = i + 1;
    };
    false
}

public fun is_network_node_online(nwn: &NetworkNode): bool {
    nwn.status.is_online()
}

public fun owner_cap_id(nwn: &NetworkNode): ID {
    nwn.owner_cap_id
}

public fun fuel_quantity(nwn: &NetworkNode): u64 {
    nwn.fuel.quantity()
}

public fun ids_length(offline_assemblies: &OfflineAssemblies): u64 {
    offline_assemblies.assembly_ids.length()
}

public fun orphaned_assemblies_length(orphaned_assemblies: &HandleOrphanedAssemblies): u64 {
    orphaned_assemblies.assembly_ids.length()
}

public fun update_energy_sources_ids_length(update_energy_sources: &UpdateEnergySources): u64 {
    update_energy_sources.assembly_ids.length()
}

/// Returns a mutable reference to the energy source
/// Package function to allow assembly module to access energy source
public(package) fun borrow_energy_source(nwn: &mut NetworkNode): &mut EnergySource {
    &mut nwn.energy_source
}

public fun need_update(nwn: &NetworkNode, fuel_config: &FuelConfig, clock: &Clock): bool {
    nwn.fuel.need_update(fuel_config, clock)
}

// === Admin Functions ===
public fun anchor(
    registry: &mut ObjectRegistry,
    character: &Character,
    admin_cap: &AdminCap,
    item_id: u64,
    type_id: u64,
    location_hash: vector<u8>,
    fuel_max_capacity: u64,
    fuel_burn_rate_in_ms: u64,
    max_energy_production: u64,
    ctx: &mut TxContext,
): NetworkNode {
    assert!(type_id != 0, ENetworkNodeTypeIdEmpty);
    assert!(item_id != 0, ENetworkNodeItemIdEmpty);

    let tenant = character.tenant();
    let nwn_key = in_game_id::create_key(item_id, tenant);
    assert!(!registry.object_exists(nwn_key), ENetworkNodeAlreadyExists);

    let nwn_uid = derived_object::claim(registry.borrow_registry_id(), nwn_key);
    let nwn_id = object::uid_to_inner(&nwn_uid);

    let owner_cap = access::create_owner_cap_by_id<NetworkNode>(admin_cap, nwn_id, ctx);
    let owner_cap_id = object::id(&owner_cap);

    let nwn = NetworkNode {
        id: nwn_uid,
        key: nwn_key,
        owner_cap_id,
        type_id,
        status: status::anchor(nwn_id, nwn_key),
        location: location::attach(location_hash),
        fuel: fuel::create(fuel_max_capacity, fuel_burn_rate_in_ms),
        energy_source: energy::create(max_energy_production),
        metadata: std::option::some(
            metadata::create_metadata(
                nwn_id,
                nwn_key,
                b"".to_string(),
                b"".to_string(),
                b"".to_string(),
            ),
        ),
        connected_assembly_ids: vector[],
    };

    access::transfer_owner_cap(owner_cap, object::id_address(character));

    event::emit(NetworkNodeCreatedEvent {
        network_node_id: nwn_id,
        assembly_key: nwn_key,
        owner_cap_id,
        type_id,
        fuel_max_capacity,
        fuel_burn_rate_in_ms,
        max_energy_production,
    });

    nwn
}

public fun share_network_node(nwn: NetworkNode, _: &AdminCap) {
    transfer::share_object(nwn);
}

/// Connects assemblies to the network node and returns a hot potato that must be consumed
/// by updating each assembly's energy source in the same transaction.
/// For each assembly, call assembly::update_energy_source_connected_assembly or
/// storage_unit::update_energy_source_connected_storage_unit, then destroy_update_energy_sources.
/// Note: UpdateEnergySources hot potato enforces that all connected assemblies
/// have their energy sources updated before the transaction completes.
public fun connect_assemblies(
    nwn: &mut NetworkNode,
    _: &AdminCap,
    assembly_ids: vector<ID>,
): UpdateEnergySources {
    let mut connected_ids = vector[];
    let mut i = 0;
    let len = assembly_ids.length();
    while (i < len) {
        let assembly_id = *vector::borrow(&assembly_ids, i);
        connect_assembly(nwn, assembly_id);
        vector::push_back(&mut connected_ids, assembly_id);
        i = i + 1;
    };
    UpdateEnergySources {
        assembly_ids: connected_ids,
    }
}

/// Unanchors the network node and returns HandleOrphanedAssemblies hot potato that must be consumed
/// by processing each connected assembly in the same transaction.
/// For each assembly call unanchor_connected_assembly or unanchor_connected_storage_unit
/// (brings offline, releases energy, clears energy source).
/// After all assemblies are processed, call destroy_network_node with the hot potato to destroy the network node.
public fun unanchor(nwn: &mut NetworkNode, _: &AdminCap): HandleOrphanedAssemblies {
    let nwn_id = object::id(nwn);
    if (nwn.energy_source.current_energy_production() > 0) {
        nwn.energy_source.stop_energy_production(nwn_id);
    };

    HandleOrphanedAssemblies {
        assembly_ids: copy_connected_assembly_ids(nwn),
    }
}

/// Destroys the network node after all connected assemblies have been processed (offline + energy source cleared)
/// Must be called after processing all assemblies from the hot potato returned by unanchor
public fun destroy_network_node(
    mut nwn: NetworkNode,
    orphaned_assemblies: HandleOrphanedAssemblies,
    _: &AdminCap,
) {
    let nwn_id = object::id(&nwn);
    orphaned_assemblies.destroy_orphaned_assemblies();
    // Clean up connected assembliesd
    let assembly_ids = copy_connected_assembly_ids(&nwn);
    if (assembly_ids.length() > 0) {
        disconnect_assemblies(&mut nwn, assembly_ids);
    };

    let NetworkNode {
        id,
        key,
        status,
        location,
        fuel,
        energy_source,
        metadata,
        connected_assembly_ids,
        ..,
    } = nwn;

    // Delete fuel and energy
    fuel::delete(fuel, nwn_id, key);
    energy::delete(energy_source);
    connected_assembly_ids.destroy_empty();

    // Clean up location, status, and metadata
    location.remove();
    status.unanchor(nwn_id, key);
    metadata.do!(|metadata| metadata.delete());

    id.delete();
}

// TODO : This does not work as expected
/// Updates fuel and returns a hot potato if the network node goes offline due to fuel depletion
/// The client must bring all connected assemblies offline using the hot potato
public fun update_fuel(
    nwn: &mut NetworkNode,
    fuel_config: &FuelConfig,
    _: &AdminCap,
    clock: &Clock,
): OfflineAssemblies {
    let nwn_id = object::id(nwn);

    if (nwn.status.is_online()) {
        // Update fuel first
        nwn.fuel.update(nwn_id, nwn.key, fuel_config, clock);

        if (!nwn.fuel.is_burning()) {
            // Fuel depleted - bring network node offline
            if (nwn.energy_source.current_energy_production() > 0) {
                nwn.energy_source.stop_energy_production(nwn_id);
            };

            nwn.status.offline(nwn_id, nwn.key);

            // Return hot potato with connected assembly IDs
            return OfflineAssemblies {
                assembly_ids: copy_connected_assembly_ids(nwn),
            }
        };
    };
    // Fuel still burning or already offline - return empty hot potato
    OfflineAssemblies {
        assembly_ids: vector[],
    }
}

/// Destroys the hot potato, ensuring all assemblies have been processed
/// Must be called at the end of the transaction after all assemblies are offline
/// The hot potato itself serves as authorization since it can only be obtained from capped functions
public fun destroy_offline_assemblies(offline_assemblies: OfflineAssemblies) {
    assert!(offline_assemblies.assembly_ids.length() == 0, EAssembliesConnected);
    let OfflineAssemblies {
        assembly_ids,
    } = offline_assemblies;
    assembly_ids.destroy_empty();
}

/// Destroys the UpdateEnergySources hot potato; call after updating energy source for each connected assembly
public fun destroy_update_energy_sources(update_energy_sources: UpdateEnergySources) {
    assert!(update_energy_sources.assembly_ids.length() == 0, EUpdateEnergySourcesNotProcessed);
    let UpdateEnergySources {
        assembly_ids,
    } = update_energy_sources;
    assembly_ids.destroy_empty();
}

/// Destroys the HandleOrphanedAssemblies hot potato; call after processing each assembly with unanchor_connected_assembly
public fun destroy_orphaned_assemblies(orphaned_assemblies: HandleOrphanedAssemblies) {
    assert!(orphaned_assemblies.assembly_ids.length() == 0, EOrphanedAssembliesNotOfflined);
    let HandleOrphanedAssemblies {
        assembly_ids,
    } = orphaned_assemblies;
    assembly_ids.destroy_empty();
}

// === Package Functions ===
/// Removes an assembly ID from the HandleOrphanedAssemblies list
public(package) fun remove_orphaned_assembly_id(
    orphaned_assemblies: &mut HandleOrphanedAssemblies,
    assembly_id: ID,
): bool {
    remove_id_from_assembly_ids(&mut orphaned_assemblies.assembly_ids, assembly_id)
}

/// Removes an assembly ID from the OfflineAssemblies list
public(package) fun remove_assembly_id(
    offline_assemblies: &mut OfflineAssemblies,
    assembly_id: ID,
): bool {
    remove_id_from_assembly_ids(&mut offline_assemblies.assembly_ids, assembly_id)
}

/// Removes an assembly ID from the UpdateEnergySources list
public(package) fun remove_energy_sources_assembly_id(
    update_energy_sources: &mut UpdateEnergySources,
    assembly_id: ID,
): bool {
    remove_id_from_assembly_ids(&mut update_energy_sources.assembly_ids, assembly_id)
}

public(package) fun connect_assembly(nwn: &mut NetworkNode, assembly_id: ID) {
    assert!(!is_assembly_connected(nwn, assembly_id), EAssemblyAlreadyConnected);
    vector::push_back(&mut nwn.connected_assembly_ids, assembly_id);
}

public(package) fun disconnect_assembly(nwn: &mut NetworkNode, assembly_id: ID) {
    let found = remove_id_from_assembly_ids(&mut nwn.connected_assembly_ids, assembly_id);
    assert!(found, EAssemblyNotConnected);
}

// === Private Functions ===
/// Removes an assembly ID from a vector of assembly IDs; returns true if found and removed
fun remove_id_from_assembly_ids(assembly_ids: &mut vector<ID>, assembly_id: ID): bool {
    let mut i = 0;
    let len = assembly_ids.length();
    while (i < len) {
        if (*vector::borrow(assembly_ids, i) == assembly_id) {
            vector::remove(assembly_ids, i);
            return true
        };
        i = i + 1;
    };
    false
}

/// Creates a copy of the connected assembly IDs vector
fun copy_connected_assembly_ids(nwn: &NetworkNode): vector<ID> {
    let mut assembly_ids = vector[];
    let mut i = 0;
    let len = nwn.connected_assembly_ids.length();
    while (i < len) {
        vector::push_back(&mut assembly_ids, *vector::borrow(&nwn.connected_assembly_ids, i));
        i = i + 1;
    };
    assembly_ids
}

fun disconnect_assemblies(nwn: &mut NetworkNode, assembly_ids: vector<ID>) {
    let mut i = 0;
    let len = assembly_ids.length();
    while (i < len) {
        let assembly_id = *vector::borrow(&assembly_ids, i);
        disconnect_assembly(nwn, assembly_id);
        i = i + 1;
    };
}
// === Test Functions ===
#[test_only]
public fun fuel(network_node: &NetworkNode): &Fuel {
    &network_node.fuel
}

#[test_only]
public fun energy(network_node: &NetworkNode): &EnergySource {
    &network_node.energy_source
}

#[test_only]
public fun status(network_node: &NetworkNode): &AssemblyStatus {
    &network_node.status
}

#[test_only]
public fun deposit_fuel_test(
    nwn: &mut NetworkNode,
    owner_cap: &OwnerCap<NetworkNode>,
    type_id: u64,
    volume: u64,
    quantity: u64,
    clock: &Clock,
) {
    let nwn_id = object::id(nwn);
    assert!(access::is_authorized(owner_cap, nwn_id), ENetworkNodeNotAuthorized);
    nwn.fuel.deposit(nwn_id, nwn.key, type_id, volume, quantity, clock);
}

#[test_only]
public fun withdraw_fuel_test(
    nwn: &mut NetworkNode,
    owner_cap: &OwnerCap<NetworkNode>,
    quantity: u64,
) {
    let nwn_id = object::id(nwn);
    assert!(access::is_authorized(owner_cap, nwn_id), ENetworkNodeNotAuthorized);
    nwn.fuel.withdraw(nwn_id, nwn.key, quantity);
}
