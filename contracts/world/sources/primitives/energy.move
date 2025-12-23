module world::energy;

use sui::{event, table::{Self, Table}};
use world::access::AdminCap;

// === Errors ===
#[error(code = 0)]
const ETypeIdEmpty: vector<u8> = b"Assembly type id cannot be empty";
#[error(code = 1)]
const EInvalidEnergyAmount: vector<u8> = b"Energy amount must be greater than 0";
#[error(code = 2)]
const EIncorrectAssemblyType: vector<u8> =
    b"Energy requirement for this assembly type is not configured";
#[error(code = 3)]
const EInsufficientAvailableEnergy: vector<u8> = b"Insufficient available energy";
#[error(code = 4)]
const EInvalidMaxEnergyProduction: vector<u8> = b"Max energy production must be greater than 0";
#[error(code = 5)]
const ENoReservedEnergy: vector<u8> = b"No energy is currently reserved";
#[error(code = 6)]
const ENotProducingEnergy: vector<u8> = b"Energy source is currently not producing energy";
#[error(code = 6)]
const EProducingEnergy: vector<u8> = b"Energy source is already producing energy";

// === Structs ===
public struct EnergyConfig has key {
    id: UID,
    assembly_energy: Table<u64, u64>,
}

public struct EnergySource has store {
    energy_source_id: ID, // network node id
    max_energy_production: u64,
    current_energy_production: u64,
    total_reserved_energy: u64,
}

// === Events ===
public struct EnergyConfigSetEvent has copy, drop {
    assembly_type_id: u64,
    energy_required: u64,
}

public struct EnergyConfigRemovedEvent has copy, drop {
    assembly_type_id: u64,
}

public struct EnergySourceCreatedEvent has copy, drop {
    energy_source_id: ID,
    max_energy_production: u64,
}

public struct StartEnergyProductionEvent has copy, drop {
    energy_source_id: ID,
    current_energy_production: u64,
}

public struct StopEnergyProductionEvent has copy, drop {
    energy_source_id: ID,
}

public struct EnergyReservedEvent has copy, drop {
    energy_source_id: ID,
    assembly_type_id: u64,
    energy_reserved: u64,
    total_reserved_energy: u64,
}

public struct EnergyReleasedEvent has copy, drop {
    energy_source_id: ID,
    assembly_type_id: u64,
    energy_released: u64,
    total_reserved_energy: u64,
}

// === View Functions ===
/// Returns the energy required for an assembly type id
public fun assembly_energy(energy_config: &EnergyConfig, type_id: u64): u64 {
    assert!(type_id != 0, ETypeIdEmpty);
    if (energy_config.assembly_energy.contains(type_id)) {
        *energy_config.assembly_energy.borrow(type_id)
    } else {
        abort EIncorrectAssemblyType
    }
}

/// Returns the total reserved energy for an energy source
public fun total_reserved_energy(energy_source: &EnergySource): u64 {
    energy_source.total_reserved_energy
}

/// Returns the available energy (current production - reserved)
public fun available_energy(energy_source: &EnergySource): u64 {
    if (energy_source.current_energy_production > energy_source.total_reserved_energy) {
        energy_source.current_energy_production - energy_source.total_reserved_energy
    } else {
        0
    }
}

/// Returns the energy source id
public fun energy_source_id(energy_source: &EnergySource): ID {
    energy_source.energy_source_id
}

/// Returns the current energy production
public fun current_energy_production(energy_source: &EnergySource): u64 {
    energy_source.current_energy_production
}

/// Returns the max energy production
public fun max_energy_production(energy_source: &EnergySource): u64 {
    energy_source.max_energy_production
}

// === Admin Functions ===
/// Sets or updates the energy requirement for an assembly type id
public fun set_energy_config(
    energy_config: &mut EnergyConfig,
    _: &AdminCap,
    assembly_type_id: u64,
    energy_required: u64,
) {
    assert!(assembly_type_id != 0, ETypeIdEmpty);
    assert!(energy_required > 0, EInvalidEnergyAmount);

    if (energy_config.assembly_energy.contains(assembly_type_id)) {
        energy_config.assembly_energy.remove(assembly_type_id);
    };
    energy_config.assembly_energy.add(assembly_type_id, energy_required);
    event::emit(EnergyConfigSetEvent {
        assembly_type_id,
        energy_required,
    });
}

/// Removes the energy configuration for an assembly type id
public fun remove_energy_config(
    energy_config: &mut EnergyConfig,
    _: &AdminCap,
    assembly_type_id: u64,
) {
    assert!(assembly_type_id != 0, ETypeIdEmpty);
    assert!(energy_config.assembly_energy.contains(assembly_type_id), EIncorrectAssemblyType);
    energy_config.assembly_energy.remove(assembly_type_id);
    event::emit(EnergyConfigRemovedEvent {
        assembly_type_id,
    });
}

// === Package Functions ===
/// Creates a new energy source with specified max energy production
public(package) fun create(energy_source_id: ID, max_energy_production: u64): EnergySource {
    assert!(max_energy_production > 0, EInvalidMaxEnergyProduction);
    let energy_source = EnergySource {
        energy_source_id,
        max_energy_production,
        current_energy_production: 0,
        total_reserved_energy: 0,
    };
    event::emit(EnergySourceCreatedEvent {
        energy_source_id,
        max_energy_production,
    });
    energy_source
}

public(package) fun start_energy_production(energy_source: &mut EnergySource) {
    assert!(energy_source.current_energy_production == 0, EProducingEnergy);
    energy_source.current_energy_production = energy_source.max_energy_production;
    event::emit(StartEnergyProductionEvent {
        energy_source_id: energy_source.energy_source_id,
        current_energy_production: energy_source.current_energy_production,
    });
}

public(package) fun stop_energy_production(energy_source: &mut EnergySource) {
    assert!(energy_source.current_energy_production > 0, ENotProducingEnergy);
    energy_source.current_energy_production = 0;
    energy_source.total_reserved_energy = 0;
    event::emit(StopEnergyProductionEvent {
        energy_source_id: energy_source.energy_source_id,
    });
}

/// Reserves energy for an assembly type
/// Requires that the energy source is currently producing energy and has available capacity
public(package) fun reserve_energy(
    energy_source: &mut EnergySource,
    energy_config: &EnergyConfig,
    type_id: u64,
) {
    assert!(type_id != 0, ETypeIdEmpty);
    assert!(energy_source.current_energy_production > 0, ENotProducingEnergy);

    let energy_required = assembly_energy(energy_config, type_id);
    let available = available_energy(energy_source);
    assert!(available >= energy_required, EInsufficientAvailableEnergy);

    energy_source.total_reserved_energy = energy_source.total_reserved_energy + energy_required;

    event::emit(EnergyReservedEvent {
        energy_source_id: energy_source.energy_source_id,
        assembly_type_id: type_id,
        energy_reserved: energy_required,
        total_reserved_energy: energy_source.total_reserved_energy,
    });
}

/// Releases energy for an assembly type
/// Requires that the energy source has reserved energy for this type
public(package) fun release_energy(
    energy_source: &mut EnergySource,
    energy_config: &EnergyConfig,
    type_id: u64,
) {
    assert!(type_id != 0, ETypeIdEmpty);
    assert!(energy_source.total_reserved_energy > 0, ENoReservedEnergy);

    let energy_required = assembly_energy(energy_config, type_id);
    assert!(energy_source.total_reserved_energy >= energy_required, EInsufficientAvailableEnergy);

    energy_source.total_reserved_energy = energy_source.total_reserved_energy - energy_required;

    event::emit(EnergyReleasedEvent {
        energy_source_id: energy_source.energy_source_id,
        assembly_type_id: type_id,
        energy_released: energy_required,
        total_reserved_energy: energy_source.total_reserved_energy,
    });
}

// === Private Functions ===
/// Initializes the EnergyConfig and shares it
fun init(ctx: &mut TxContext) {
    transfer::share_object(EnergyConfig {
        id: object::new(ctx),
        assembly_energy: table::new(ctx),
    })
}

// === Test Functions ===
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
