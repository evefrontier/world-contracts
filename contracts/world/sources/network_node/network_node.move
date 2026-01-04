/// This module handles the in-game Network Node functionality
///
/// The Network node is an energy source for all the assemblies connected to it
/// It can be fuelled and burn fuel to produce energy in GJ
/// This energy can be used by the assemblies to perform actions like online, bridging items, etc
/// Assemblies have to be connected to network node to reserve and release energy
///
/// Future: There might be multiple power sources connected together to generate more energy that can be used by assemblies in the base
module world::network_node;

use std::string::String;
use sui::{clock::Clock, derived_object, event};
use world::{
    access::{Self, OwnerCap, AdminCap},
    energy::{Self, EnergySource},
    fuel::{Self, FuelConfig, Fuel},
    in_game_id::{Self, TenantItemId},
    location::{Self, Location},
    metadata::{Self, Metadata},
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

// ENetworkNodeDoesNotExist
// ENetworkNodeInsufficientEnergy
// ENetworkNodeNotProducingEnergy

// === Structs ===
public struct NetworkNodeRegistry has key {
    id: UID,
}

public struct NetworkNode has key {
    id: UID,
    key: TenantItemId,
    owner_cap_id: ID,
    type_id: u64,
    volume: u64,
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
    key: TenantItemId,
    type_id: u64,
    volume: u64,
    fuel_max_capacity: u64,
    fuel_burn_rate_in_ms: u64,
    max_energy_production: u64,
}

// === Public Functions ===
public fun deposit_fuel(
    nwn: &mut NetworkNode,
    owner_cap: &OwnerCap<NetworkNode>,
    type_id: u64,
    volume: u64,
    quantity: u64,
    clock: &Clock,
) {
    assert!(access::is_authorized(owner_cap, object::id(nwn)), ENetworkNodeNotAuthorized);
    nwn.fuel.deposit(type_id, volume, quantity, clock);
}

public fun withdraw_fuel(nwn: &mut NetworkNode, owner_cap: &OwnerCap<NetworkNode>, quantity: u64) {
    assert!(access::is_authorized(owner_cap, object::id(nwn)), ENetworkNodeNotAuthorized);
    nwn.fuel.withdraw(quantity);
}

public fun online(nwn: &mut NetworkNode, owner_cap: &OwnerCap<NetworkNode>, clock: &Clock) {
    assert!(access::is_authorized(owner_cap, object::id(nwn)), ENetworkNodeNotAuthorized);
    nwn.fuel.start_burning(clock);
    nwn.energy_source.start_energy_production();
    nwn.status.online();
}

// todo : this should also bring all the connected assemblies offline
// this can be done in PTB, but to enforce this we should consider hot potato pattern
public fun offline(
    nwn: &mut NetworkNode,
    fuel_config: &FuelConfig,
    owner_cap: &OwnerCap<NetworkNode>,
    clock: &Clock,
) {
    assert!(access::is_authorized(owner_cap, object::id(nwn)), ENetworkNodeNotAuthorized);
    assert!(nwn.status.is_online(), ENetworkNodeOffline);

    // Update fuel first to consume any pending fuel
    nwn.fuel.update(fuel_config, clock);

    if (nwn.fuel.is_burning()) {
        nwn.fuel.stop_burning(fuel_config, clock);
    };

    if (nwn.energy_source.current_energy_production() > 0) {
        nwn.energy_source.stop_energy_production();
    };

    nwn.status.offline();
}

// === View Functions ===
/// Returns the list of connected assembly IDs
public fun connected_assemblies(nwn: &NetworkNode): vector<ID> {
    nwn.connected_assembly_ids
}

/// Checks if an assembly is connected to this network node
public fun is_assembly_connected(nwn: &NetworkNode, assembly_id: ID): bool {
    let mut i = 0;
    let len = vector::length(&nwn.connected_assembly_ids);
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

// === Admin Functions ===
public fun anchor(
    nwn_registry: &mut NetworkNodeRegistry,
    admin_cap: &AdminCap,
    character_address: address,
    tenant: String,
    item_id: u64,
    type_id: u64,
    volume: u64,
    location_hash: vector<u8>,
    fuel_max_capacity: u64,
    fuel_burn_rate_in_ms: u64,
    max_energy_production: u64,
    ctx: &mut TxContext,
): NetworkNode {
    assert!(type_id != 0, ENetworkNodeTypeIdEmpty);
    assert!(item_id != 0, ENetworkNodeItemIdEmpty);

    let nwn_key = in_game_id::create_key(item_id, tenant);
    assert!(!nwn_exists(nwn_registry, nwn_key), ENetworkNodeAlreadyExists);

    let nwn_uid = derived_object::claim(&mut nwn_registry.id, nwn_key);
    let nwn_id = object::uid_to_inner(&nwn_uid);

    let owner_cap_id = access::create_and_transfer_owner_cap<NetworkNode>(
        admin_cap,
        nwn_id,
        character_address,
        ctx,
    );

    let nwn = NetworkNode {
        id: nwn_uid,
        key: nwn_key,
        owner_cap_id,
        type_id,
        volume,
        status: status::anchor(nwn_id, type_id, item_id),
        location: location::attach(nwn_id, location_hash),
        fuel: fuel::create(nwn_id, fuel_max_capacity, fuel_burn_rate_in_ms),
        energy_source: energy::create(nwn_id, max_energy_production),
        metadata: std::option::some(
            metadata::create_metadata(
                nwn_id,
                item_id,
                b"".to_string(),
                b"".to_string(),
                b"".to_string(),
            ),
        ),
        connected_assembly_ids: vector[],
    };

    event::emit(NetworkNodeCreatedEvent {
        network_node_id: nwn_id,
        key: nwn_key,
        type_id,
        volume,
        fuel_max_capacity,
        fuel_burn_rate_in_ms,
        max_energy_production,
    });

    nwn
}

public fun share_network_node(nwn: NetworkNode, _: &AdminCap) {
    transfer::share_object(nwn);
}

public fun connect_assemblies(nwn: &mut NetworkNode, _: &AdminCap, assembly_ids: vector<ID>) {
    let mut i = 0;
    let len = vector::length(&assembly_ids);
    while (i < len) {
        let assembly_id = *vector::borrow(&assembly_ids, i);
        connect_assembly(nwn, assembly_id);
        i = i + 1;
    };
}

public fun disconnect_assemblies(nwn: &mut NetworkNode, _: &AdminCap, assembly_ids: vector<ID>) {
    let mut i = 0;
    let len = vector::length(&assembly_ids);
    while (i < len) {
        let assembly_id = *vector::borrow(&assembly_ids, i);
        disconnect_assembly(nwn, assembly_id);
        i = i + 1;
    };
}

/// Unanchors the network node
/// Requires all connected assemblies to be disconnected
public fun unanchor(nwn: NetworkNode, _: &AdminCap) {
    let NetworkNode {
        id,
        status,
        location,
        fuel,
        energy_source,
        metadata,
        connected_assembly_ids,
        ..,
    } = nwn;

    // A cron job must call assembly::offline() for each connected assembly and disconnect assemblies
    assert!(vector::length(&connected_assembly_ids) == 0, EAssembliesConnected);

    // Delete fuel and energy
    fuel::delete(fuel);
    energy::delete(energy_source);

    // Clean up connected assemblies, location, status, and metadata
    connected_assembly_ids.destroy_empty();
    location.remove();
    status.unanchor();
    metadata.do!(|metadata| metadata.delete());

    id.delete();
}

// === Package Functions ===
public(package) fun connect_assembly(nwn: &mut NetworkNode, assembly_id: ID) {
    assert!(!is_assembly_connected(nwn, assembly_id), EAssemblyAlreadyConnected);
    vector::push_back(&mut nwn.connected_assembly_ids, assembly_id);
}

public(package) fun disconnect_assembly(nwn: &mut NetworkNode, assembly_id: ID) {
    let mut i = 0;
    let len = vector::length(&nwn.connected_assembly_ids);
    let mut found = false;
    while (i < len) {
        if (*vector::borrow(&nwn.connected_assembly_ids, i) == assembly_id) {
            vector::remove(&mut nwn.connected_assembly_ids, i);
            found = true;
            break
        };
        i = i + 1;
    };
    assert!(found, EAssemblyNotConnected);
}

// Note: The cron job should iterate through connected_assemblies() and call
// assembly::offline() for each connected assembly that is still online
// consider hot potato pattern
public(package) fun update_fuel(nwn: &mut NetworkNode, fuel_config: &FuelConfig, clock: &Clock) {
    // Update fuel first
    nwn.fuel.update(fuel_config, clock);

    if (!nwn.fuel.is_burning()) {
        if (nwn.energy_source.current_energy_production() > 0) {
            nwn.energy_source.stop_energy_production();
        };

        nwn.status.offline();
    };
}

public(package) fun nwn_exists(registry: &NetworkNodeRegistry, key: TenantItemId): bool {
    derived_object::exists(&registry.id, key)
}

// === Private Functions ===
fun init(ctx: &mut TxContext) {
    transfer::share_object(NetworkNodeRegistry {
        id: object::new(ctx),
    });
}

// === Test Functions ===
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

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
