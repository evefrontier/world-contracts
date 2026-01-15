/// This module implements the CrudeLift assembly for mining crude matter from rifts.
///
/// A CrudeLift is a mining assembly that can extract crude matter from rifts.
/// It requires a lens for mining operations and consumes fuel while operating.
/// Only one CrudeLift can mine a rift at a time, and mining continues until
/// the lens is exhausted, fuel runs out, rift collapses, or inventory is full.
module world::crude_lift;

use sui::{
    clock::Clock,
    derived_object,
    dynamic_field as df,
    event
};
use world::{
    access::{Self, OwnerCap, AdminCap},
    character::Character,
    energy,
    energy::EnergyConfig,
    fuel::{Self, Fuel, FuelConfig},
    in_game_id::{Self, TenantItemId},
    inventory::{Self, Inventory},
    location::{Self, Location},
    metadata::{Self, Metadata},
    network_node::NetworkNode,
    object_registry::{Self, ObjectRegistry},
    rift::Rift,
    status::{Self, AssemblyStatus}
};

// Constants
const CRUDE_MATTER_TYPE_ID: u64 = 1;
const CRUDE_VOLUME: u64 = 1;
const DEFAULT_FUEL_MAX_CAPACITY: u64 = 10000;
const DEFAULT_FUEL_BURN_RATE_SECONDS: u64 = 3600; // 1 hour in seconds

// === Errors ===
#[error(code = 0)]
const EAlreadyMining: vector<u8> = b"Already mining";
#[error(code = 1)]
const ENotMining: vector<u8> = b"Not mining";
#[error(code = 2)]
#[allow(unused_const)]
const ERiftCollapsed: vector<u8> = b"Rift has collapsed";
#[error(code = 3)]
#[allow(unused_const)]
const EInsufficientCrude: vector<u8> = b"Insufficient crude matter";
#[error(code = 4)]
const ECrudeLiftWrongState: vector<u8> = b"CrudeLift in wrong state for operation";

// === Structs ===

/// Represents the mining state of a CrudeLift
public struct MiningState has store, drop, copy {
    /// ID of the rift being mined
    rift_id: ID,
    /// Timestamp when mining started
    start_time: u64,
    /// Mining rate (crude matter per second)
    mining_rate: u64,
}

/// The main CrudeLift assembly for mining operations
public struct CrudeLift has key {
    id: UID,
    key: TenantItemId,
    owner_cap_id: ID,
    type_id: u64,
    status: AssemblyStatus,
    location: Location,
    energy_source_id: ID,
    inventory_keys: vector<ID>,
    metadata: Option<Metadata>,
}

// === Events ===

public struct CrudeLiftCreatedEvent has copy, drop {
    crude_lift_id: ID,
    key: TenantItemId,
    type_id: u64,
    max_inventory_capacity: u64,
    ephemeral_inventory_capacity: u64,
    location_hash: vector<u8>,
}


public struct MiningStartedEvent has copy, drop {
    crude_lift_id: ID,
    rift_id: ID,
    mining_rate: u64,
    start_time: u64,
}

public struct MiningStoppedEvent has copy, drop {
    crude_lift_id: ID,
    rift_id: ID,
    crude_mined: u64,
    mining_duration: u64,
    fuel_consumed: u64,
}

// === Public Functions ===

// === View Functions ===

/// Returns the owner capability ID for this CrudeLift
public fun owner_cap_id(crude_lift: &CrudeLift): ID {
    crude_lift.owner_cap_id
}

/// Returns the status of the CrudeLift
public fun status(crude_lift: &CrudeLift): &AssemblyStatus {
    &crude_lift.status
}

/// Returns the location of the CrudeLift
public fun location(crude_lift: &CrudeLift): &Location {
    &crude_lift.location
}

/// Returns the location hash of the CrudeLift
public fun location_hash(crude_lift: &CrudeLift): vector<u8> {
    location::hash(&crude_lift.location)
}

/// Returns whether the CrudeLift is online
public fun is_online(crude_lift: &CrudeLift): bool {
    crude_lift.status.is_online()
}

/// Returns whether the CrudeLift is currently mining
public fun is_mining(crude_lift: &CrudeLift): bool {
    df::exists_(&crude_lift.id, b"mining_state")
}

/// Returns the current mining state if mining, None otherwise
public fun mining_state(crude_lift: &CrudeLift): Option<MiningState> {
    if (crude_lift.is_mining()) {
        option::some(*df::borrow(&crude_lift.id, b"mining_state"))
    } else {
        option::none()
    }
}


/// Returns the amount of crude matter in the CrudeLift's inventory
public fun crude_amount(crude_lift: &CrudeLift): u64 {
    let inventory = df::borrow<ID, Inventory>(&crude_lift.id, crude_lift.owner_cap_id);
    // Use a deterministic item ID for crude matter
    let crude_item_id = 1; // Fixed item ID for crude matter
    if (inventory.contains_item(crude_item_id)) {
        inventory::item_quantity(inventory, crude_item_id) as u64
    } else {
        0
    }
}

/// Returns the inventory capacity of the CrudeLift
public fun inventory_capacity(crude_lift: &CrudeLift): u64 {
    let inventory = df::borrow<ID, Inventory>(&crude_lift.id, crude_lift.owner_cap_id);
    inventory.max_capacity()
}

// === Owner Functions (require OwnerCap) ===

/// Brings the CrudeLift online
public fun online(
    crude_lift: &mut CrudeLift,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    owner_cap: &OwnerCap<CrudeLift>,
) {
    assert!(access::is_authorized(owner_cap, object::id(crude_lift)), ECrudeLiftWrongState);
    if (crude_lift.energy_source_id == object::id_from_address(@0x0)) {
        network_node.connect_assembly(object::id(crude_lift));
        crude_lift.energy_source_id = object::id(network_node);
    } else {
        assert!(crude_lift.energy_source_id == object::id(network_node), ECrudeLiftWrongState);
    };
    
    // Reserve energy from the network node before going online.
    let energy_source = network_node.borrow_energy_source();
    energy::reserve_energy(energy_source, energy_config, crude_lift.type_id);
    crude_lift.status.online();
}

/// Takes the CrudeLift offline
public fun offline(
    crude_lift: &mut CrudeLift,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    owner_cap: &OwnerCap<CrudeLift>,
) {
    assert!(access::is_authorized(owner_cap, object::id(crude_lift)), ECrudeLiftWrongState);
    assert!(!crude_lift.is_mining(), ECrudeLiftWrongState); // Cannot offline while mining
    assert!(crude_lift.energy_source_id == object::id(network_node), ECrudeLiftWrongState);
    
    let energy_source = network_node.borrow_energy_source();
    energy::release_energy(energy_source, energy_config, crude_lift.type_id);
    crude_lift.status.offline();
}


/// Starts mining operations on a rift
public fun start_mining(
    crude_lift: &mut CrudeLift,
    rift: &mut Rift,
    mining_rate: u64,
    clock: &Clock,
    owner_cap: &OwnerCap<CrudeLift>,
) {
    assert!(access::is_authorized(owner_cap, object::id(crude_lift)), ECrudeLiftWrongState);
    assert!(crude_lift.is_online(), ECrudeLiftWrongState);
    assert!(!crude_lift.is_mining(), EAlreadyMining);
    assert!(rift.can_start_mining(), EAlreadyMining);

    let start_time = clock.timestamp_ms();

    // Start mining on the rift
    rift.start_mining(object::id(crude_lift));

    // Set mining state
    let mining_state = MiningState {
        rift_id: object::id(rift),
        start_time,
        mining_rate,
    };
    df::add(&mut crude_lift.id, b"mining_state", mining_state);

    event::emit(MiningStartedEvent {
        crude_lift_id: object::id(crude_lift),
        rift_id: object::id(rift),
        mining_rate,
        start_time,
    });
}

/// Stops mining operations
/// This will calculate and collect crude matter based on mining duration
public fun stop_mining(
    crude_lift: &mut CrudeLift,
    rift: &mut Rift,
    fuel_config: &FuelConfig,
    character: &Character,
    clock: &Clock,
    owner_cap: &OwnerCap<CrudeLift>,
    ctx: &mut TxContext,
) {
    assert!(access::is_authorized(owner_cap, object::id(crude_lift)), ECrudeLiftWrongState);
    assert!(crude_lift.is_mining(), ENotMining);

    let mining_state: MiningState = df::remove(&mut crude_lift.id, b"mining_state");
    let current_time = clock.timestamp_ms();
    let crude_lift_id = object::id(crude_lift);

    // Calculate mining duration, accounting for rift collapse
    let rift_collapsed_at = rift.collapsed_at();
    let mut mining_duration = current_time - mining_state.start_time;

    if (rift_collapsed_at.is_some() && *rift_collapsed_at.borrow() > mining_state.start_time) {
        let collapse_time = *rift_collapsed_at.borrow();
        if (collapse_time < current_time) {
            mining_duration = collapse_time - mining_state.start_time;
        }
    };

    // Update fuel consumption and calculate fuel-related values
    let has_fuel;
    let fuel_consumed;
    {
        let fuel: &mut Fuel = df::borrow_mut(&mut crude_lift.id, b"fuel");
        fuel.update(fuel_config, clock);

        // Check if fuel ran out and adjust mining duration
        has_fuel = fuel.has_enough_fuel(fuel_config, clock);
        if (!has_fuel) {
            // Calculate how long fuel lasted
            // Note: Simplified calculation - in production would need proper fuel consumption tracking
            let fuel_quantity = fuel.quantity();
            if (fuel_quantity > 0) {
                let fuel_duration_ms = fuel_quantity * 1000; // Rough estimate
                if (fuel_duration_ms < mining_duration) {
                    mining_duration = fuel_duration_ms;
                }
            }
        };
        fuel_consumed = if (has_fuel) { mining_duration / 1000 } else { fuel.quantity() };
    };

    // Calculate crude mined (limited by available crude in rift)
    let crude_mined = (mining_state.mining_rate * mining_duration / 1000).min(rift.crude_amount());

    // Remove crude from rift and add to inventory
    if (crude_mined > 0) {
        if (!rift.is_collapsed()) {
            rift.remove_crude(crude_mined);
        };
        add_crude_to_inventory(crude_lift, character, crude_mined, ctx);
    };

    // Stop mining on rift
    rift.stop_mining(crude_lift_id);

    event::emit(MiningStoppedEvent {
        crude_lift_id,
        rift_id: mining_state.rift_id,
        crude_mined,
        mining_duration,
        fuel_consumed,
    });
}

// === Admin Functions ===

/// Creates and anchors a new CrudeLift
public fun anchor(
    assembly_registry: &mut ObjectRegistry,
    character: &Character,
    admin_cap: &AdminCap,
    item_id: u64,
    type_id: u64,
    max_inventory_capacity: u64,
    ephemeral_inventory_capacity: u64,
    location_hash: vector<u8>,
    ctx: &mut TxContext,
): CrudeLift {
    assert!(type_id != 0, ECrudeLiftWrongState);
    assert!(item_id != 0, ECrudeLiftWrongState);

    let tenant = character.tenant();
    let crude_lift_key = in_game_id::create_key(item_id, tenant);
    assert!(
        !object_registry::object_exists(assembly_registry, crude_lift_key),
        ECrudeLiftWrongState,
    );

    let registry_id = object_registry::borrow_registry_id(assembly_registry);
    let assembly_uid = derived_object::claim(registry_id, crude_lift_key);
    let assembly_id = object::uid_to_inner(&assembly_uid);

    // Create owner cap
    let owner_cap_id = access::create_and_transfer_owner_cap<CrudeLift>(
        admin_cap,
        assembly_id,
        character.character_address(),
        ctx,
    );

    let mut crude_lift = CrudeLift {
        id: assembly_uid,
        key: crude_lift_key,
        owner_cap_id,
        type_id,
        status: status::anchor(assembly_id, type_id, item_id),
        location: location::attach(assembly_id, location_hash),
        energy_source_id: object::id_from_address(@0x0), // Will be set when connected to network node
        inventory_keys: vector[],
        metadata: option::some(
            metadata::create_metadata(
                assembly_id,
                item_id,
                b"".to_string(),
                b"".to_string(),
                b"".to_string(),
            ),
        ),
    };

    // Create inventories
    let owner_inventory = inventory::create(
        assembly_id,
        crude_lift_key,
        owner_cap_id,
        max_inventory_capacity,
    );

    crude_lift.inventory_keys.push_back(owner_cap_id);
    df::add(&mut crude_lift.id, owner_cap_id, owner_inventory);

    // Create fuel system
    let burn_rate_ms = DEFAULT_FUEL_BURN_RATE_SECONDS * 1000;
    let fuel = fuel::create(assembly_id, DEFAULT_FUEL_MAX_CAPACITY, burn_rate_ms);
    df::add(&mut crude_lift.id, b"fuel", fuel);

    event::emit(CrudeLiftCreatedEvent {
        crude_lift_id: assembly_id,
        key: crude_lift_key,
        type_id,
        max_inventory_capacity,
        ephemeral_inventory_capacity,
        location_hash,
    });

    crude_lift
}

/// Shares the CrudeLift as a shared object
public fun share_crude_lift(crude_lift: CrudeLift, _: &AdminCap) {
    transfer::share_object(crude_lift);
}

// === Private Functions ===

/// Adds crude matter to the CrudeLift's inventory
fun add_crude_to_inventory(
    crude_lift: &mut CrudeLift,
    character: &Character,
    amount: u64,
    ctx: &mut TxContext,
) {
    let inventory = df::borrow_mut<ID, Inventory>(
        &mut crude_lift.id,
        crude_lift.owner_cap_id,
    );

    let crude_item_id = 1; // Fixed item ID for crude matter

    // Mint crude matter items into inventory
    inventory.mint_items(
        character,
        crude_lift.key.tenant(),
        crude_item_id,
        CRUDE_MATTER_TYPE_ID,
        CRUDE_VOLUME,
        amount as u32,
        crude_lift.location.hash(),
        ctx,
    );
}

// === Init ===

fun init(_ctx: &mut TxContext) {
    // CrudeLift assembly doesn't require shared object initialization
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

// === Test Functions ===

#[test_only]
public fun inventory(crude_lift: &CrudeLift, owner_cap_id: ID): &Inventory {
    df::borrow(&crude_lift.id, owner_cap_id)
}

#[test_only]
public fun borrow_status_mut(crude_lift: &mut CrudeLift): &mut AssemblyStatus {
    &mut crude_lift.status
}

#[test_only]
public fun item_quantity(crude_lift: &CrudeLift, owner_cap_id: ID, item_id: u64): u32 {
    let inventory = df::borrow<ID, Inventory>(&crude_lift.id, owner_cap_id);
    inventory.item_quantity(item_id)
}

#[test_only]
public fun has_inventory(crude_lift: &CrudeLift, owner_cap_id: ID): bool {
    df::exists_(&crude_lift.id, owner_cap_id)
}
