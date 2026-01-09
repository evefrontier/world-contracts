// TODO: Add Fuel module to handle fuel operations like refueling, etc.
module world::fuel;

use sui::{clock::Clock, event, table::{Self, Table}};
use world::access::AdminCap;

// === Errors ===
#[error(code = 0)]
const ETypeIdEmtpy: vector<u8> = b"Fuel Type Id cannot be empty";
#[error(code = 1)]
const EInvalidFuelEfficiency: vector<u8> = b"Invalid Fuel Efficiency";
#[error(code = 2)]
const EIncorrectFuelType: vector<u8> = b"Fuel Efficiency for this fuel type is not configured";
#[error(code = 3)]
const EInsufficientFuel: vector<u8> = b"Insufficient fuel quantity";
#[error(code = 4)]
const EInvalidDepositQuantity: vector<u8> = b"Deposit quantity must be greater than 0";
#[error(code = 5)]
const EInvalidWithdrawQuantity: vector<u8> = b"Withdraw quantity must be greater than 0";
#[error(code = 6)]
const EFuelCapacityExceeded: vector<u8> = b"Fuel capacity would be exceeded";
#[error(code = 7)]
const EInvalidMaxCapacity: vector<u8> = b"Fuel max capacity must be greater than 0";
#[error(code = 8)]
const EInvalidVolume: vector<u8> = b"Fuel volume must be greater than 0";
#[error(code = 9)]
const EFuelTypeMismatch: vector<u8> =
    b"Cannot deposit fuel of different type. Withdraw existing fuel first";
#[error(code = 10)]
const EInvalidBurnRate: vector<u8> = b"Burn rate must be at least the minimum configured burn rate";
#[error(code = 11)]
const EFuelNotBurning: vector<u8> = b"Fuel is not currently burning";
#[error(code = 12)]
const EFuelAlreadyBurning: vector<u8> = b"Fuel is already burning";
#[error(code = 13)]
const ENoFuelToBurn: vector<u8> = b"No fuel available to burn";

// === Constants ===
const MIN_BURN_RATE_SECONDS: u64 = 60;
const MILLISECONDS_PER_SECOND: u64 = 1000;
const MIN_BURN_RATE_MS: u64 = MIN_BURN_RATE_SECONDS * MILLISECONDS_PER_SECOND;
const MIN_FUEL_EFFICIENCY: u64 = 10;
const MAX_FUEL_EFFICIENCY: u64 = 100;
const PERCENTAGE_DIVISOR: u64 = 100;

// === Structs ===
public struct FuelConfig has key {
    id: UID,
    fuel_efficiency: Table<u64, u64>,
}

public struct Fuel has store {
    assembly_id: ID,
    max_capacity: u64,
    burn_rate_in_ms: u64,
    type_id: Option<u64>,
    unit_volume: Option<u64>,
    quantity: u64,
    is_burning: bool,
    previous_cycle_elapsed_time: u64,
    burn_start_time: u64,
    last_updated: u64,
}

// === Events ===
public struct FuelDepositedEvent has copy, drop {
    assembly_id: ID,
    type_id: u64,
    unit_volume: u64,
    quantity: u64,
    total_quantity: u64,
}

public struct FuelWithdrawnEvent has copy, drop {
    assembly_id: ID,
    type_id: u64,
    quantity: u64,
    remaining_quantity: u64,
}

public struct FuelBurningStartedEvent has copy, drop {
    assembly_id: ID,
    type_id: u64,
    quantity: u64,
    burn_start_time: u64,
}

public struct FuelBurningStoppedEvent has copy, drop {
    assembly_id: ID,
    type_id: u64,
    quantity: u64,
    previous_cycle_elapsed_time: u64,
}

public struct FuelUpdatedEvent has copy, drop {
    assembly_id: ID,
    type_id: u64,
    units_consumed: u64,
    remaining_quantity: u64,
    is_burning: bool,
}

public struct FuelEfficiencySetEvent has copy, drop {
    fuel_type_id: u64,
    efficiency: u64,
}

public struct FuelEfficiencyRemovedEvent has copy, drop {
    fuel_type_id: u64,
}

// === View Functions ===
public fun fuel_efficiency(fuel_config: &FuelConfig, fuel_type_id: u64): u64 {
    if (fuel_config.fuel_efficiency.contains(fuel_type_id)) {
        *fuel_config.fuel_efficiency.borrow(fuel_type_id)
    } else {
        abort EIncorrectFuelType
    }
}

public fun quantity(fuel: &Fuel): u64 {
    fuel.quantity
}

public fun type_id(fuel: &Fuel): Option<u64> {
    fuel.type_id
}

public fun volume(fuel: &Fuel): Option<u64> {
    fuel.unit_volume
}

public fun is_burning(fuel: &Fuel): bool {
    fuel.is_burning
}

/// Checks if fuel has enough quantity to cover units that would be consumed at current time
public fun has_enough_fuel(fuel: &Fuel, fuel_config: &FuelConfig, clock: &Clock): bool {
    if (!fuel.is_burning) return false;

    let (units_to_consume, _) = calculate_units_to_consume(
        fuel,
        fuel_config,
        clock.timestamp_ms(),
    );

    fuel.quantity >= units_to_consume
}

/// Checks if fuel state needs to be updated based on elapsed time since last update.
/// Returns true if there are any fuel units needs to be consumed, false otherwise.
/// Useful for cron jobs to determine if `update()` should be called.
public fun need_update(fuel: &Fuel, fuel_config: &FuelConfig, clock: &Clock): bool {
    if (!fuel.is_burning) return false;

    let (units_to_consume, _) = calculate_units_to_consume(
        fuel,
        fuel_config,
        clock.timestamp_ms(),
    );

    units_to_consume > 0
}

// === Admin Functions ===
/// Sets or updates the fuel efficiency percentage for a fuel type (10-100%)
public fun set_fuel_efficiency(
    fuel_config: &mut FuelConfig,
    _: &AdminCap,
    fuel_type_id: u64,
    fuel_efficiency: u64,
) {
    assert!(fuel_type_id != 0, ETypeIdEmtpy);
    assert!(
        fuel_efficiency >= MIN_FUEL_EFFICIENCY && fuel_efficiency <= MAX_FUEL_EFFICIENCY,
        EInvalidFuelEfficiency,
    );
    if (fuel_config.fuel_efficiency.contains(fuel_type_id)) {
        fuel_config.fuel_efficiency.remove(fuel_type_id);
    };
    fuel_config.fuel_efficiency.add(fuel_type_id, fuel_efficiency);
    event::emit(FuelEfficiencySetEvent {
        fuel_type_id,
        efficiency: fuel_efficiency,
    });
}

/// Removes the fuel efficiency configuration for a fuel type
public fun unset_fuel_efficiency(fuel_config: &mut FuelConfig, _: &AdminCap, fuel_type_id: u64) {
    assert!(fuel_type_id != 0, ETypeIdEmtpy);
    fuel_config.fuel_efficiency.remove(fuel_type_id);
    event::emit(FuelEfficiencyRemovedEvent {
        fuel_type_id,
    });
}

// === Package Functions ===
/// Creates a new fuel object with specified capacity and burn rate (in milliseconds)
public(package) fun create(assembly_id: ID, max_capacity: u64, burn_rate_in_ms: u64): Fuel {
    assert!(max_capacity > 0, EInvalidMaxCapacity);
    assert!(burn_rate_in_ms >= MIN_BURN_RATE_MS, EInvalidBurnRate);
    Fuel {
        assembly_id,
        max_capacity,
        burn_rate_in_ms,
        type_id: option::none(),
        unit_volume: option::none(),
        quantity: 0,
        is_burning: false,
        previous_cycle_elapsed_time: 0,
        burn_start_time: 0,
        last_updated: 0,
    }
}

/// Deposits fuel of a specific type. Initializes fuel type if empty, or verifies type matches.
/// Resets time tracking if fuel was empty and burning was active.
public(package) fun deposit(
    fuel: &mut Fuel,
    type_id: u64,
    unit_volume: u64,
    quantity: u64,
    clock: &Clock,
) {
    assert!(quantity > 0, EInvalidDepositQuantity);
    assert!(unit_volume > 0, EInvalidVolume);
    assert!(type_id != 0, ETypeIdEmtpy);

    // Initialize or verify fuel type matches
    if (option::is_none(&fuel.type_id) || fuel.quantity == 0) {
        if (fuel.is_burning) {
            // reset time tracking - the burning will continue with new fuel
            fuel.burn_start_time = clock.timestamp_ms();
            fuel.previous_cycle_elapsed_time = 0;
        } else {
            fuel.burn_start_time = 0;
            fuel.previous_cycle_elapsed_time = 0;
        };
        fuel.type_id = option::some(type_id);
        fuel.unit_volume = option::some(unit_volume);
    } else {
        assert!(option::is_some(&fuel.type_id), EFuelTypeMismatch);
        assert!(*option::borrow(&fuel.type_id) == type_id, EFuelTypeMismatch);
    };

    assert!(option::is_some(&fuel.unit_volume), EInvalidVolume);
    let new_quantity = fuel.quantity + quantity;
    let unit_vol = *option::borrow(&fuel.unit_volume);
    assert!(unit_vol * new_quantity <= fuel.max_capacity, EFuelCapacityExceeded);
    fuel.quantity = new_quantity;
    event::emit(FuelDepositedEvent {
        assembly_id: fuel.assembly_id,
        type_id,
        unit_volume,
        quantity,
        total_quantity: new_quantity,
    });
}

/// Withdraws specified quantity of fuel. Fails if insufficient fuel available.
public(package) fun withdraw(fuel: &mut Fuel, quantity: u64) {
    assert!(quantity > 0, EInvalidWithdrawQuantity);
    assert!(fuel.quantity >= quantity, EInsufficientFuel);
    assert!(option::is_some(&fuel.type_id), ETypeIdEmtpy);
    fuel.quantity = fuel.quantity - quantity;
    event::emit(FuelWithdrawnEvent {
        assembly_id: fuel.assembly_id,
        type_id: *option::borrow(&fuel.type_id),
        quantity,
        remaining_quantity: fuel.quantity,
    });
}

/// Starts burning fuel. Consumes 1 unit immediately and sets burn_start_time.
/// Requires fuel quantity > 0 or previous_cycle_elapsed_time > 0.
public(package) fun start_burning(fuel: &mut Fuel, clock: &Clock) {
    assert!(!fuel.is_burning, EFuelAlreadyBurning);
    assert!(fuel.quantity > 0 || fuel.previous_cycle_elapsed_time > 0, ENoFuelToBurn);
    assert!(option::is_some(&fuel.type_id), ETypeIdEmtpy);

    // todo : should we check if last_updated is the current block ?

    fuel.is_burning = true;
    fuel.burn_start_time = clock.timestamp_ms();
    if (fuel.quantity != 0) {
        fuel.quantity = fuel.quantity - 1; // Consume 1 unit to start the clock
    };
    let fuel_type_id = *option::borrow(&fuel.type_id);
    event::emit(FuelBurningStartedEvent {
        assembly_id: fuel.assembly_id,
        type_id: fuel_type_id,
        quantity: fuel.quantity,
        burn_start_time: fuel.burn_start_time,
    });
}

/// Stops burning fuel. Saves remaining elapsed time for next burn cycle
public(package) fun stop_burning(fuel: &mut Fuel, fuel_config: &FuelConfig, clock: &Clock) {
    assert!(fuel.is_burning, EFuelNotBurning);

    let current_time_ms = clock.timestamp_ms();
    let (units_to_consume, remaining_elapsed_ms) = calculate_units_to_consume(
        fuel,
        fuel_config,
        current_time_ms,
    );

    // Update previous_cycle_elapsed_time with remaining time for next cycle
    // only if the last unit is being burned
    if (fuel.quantity >= units_to_consume) {
        fuel.previous_cycle_elapsed_time = remaining_elapsed_ms;
    } else {
        fuel.previous_cycle_elapsed_time = 0;
    };
    fuel.burn_start_time = 0;
    fuel.is_burning = false;
    let fuel_type_id = *option::borrow(&fuel.type_id);
    event::emit(FuelBurningStoppedEvent {
        assembly_id: fuel.assembly_id,
        type_id: fuel_type_id,
        quantity: fuel.quantity,
        previous_cycle_elapsed_time: fuel.previous_cycle_elapsed_time,
    });
}

public(package) fun delete(fuel: Fuel) {
    let Fuel {
        ..,
    } = fuel;
}

/// Updates fuel consumption state. Consumes units based on elapsed time since last update.
/// If there is not enough fuel to consume, then stop burning
public(package) fun update(fuel: &mut Fuel, fuel_config: &FuelConfig, clock: &Clock) {
    if (!fuel.is_burning || fuel.burn_start_time == 0) {
        return
    };

    let current_time_ms = clock.timestamp_ms();
    if (fuel.last_updated == current_time_ms) {
        return
    };

    let (units_to_consume, remaining_elapsed_ms) = calculate_units_to_consume(
        fuel,
        fuel_config,
        current_time_ms,
    );

    // consume only if there is enough fuel
    if (fuel.quantity >= units_to_consume) {
        consume_fuel_units(
            fuel,
            units_to_consume,
            remaining_elapsed_ms,
            current_time_ms,
        );

        fuel.last_updated = current_time_ms;
    } else {
        // stop burning
        stop_burning(fuel, fuel_config, clock);
    }
}

// === Private Functions ===
/// Consumes fuel units based on elapsed time, capping at available quantity.
/// Updates burn_start_time and emits FuelUpdatedEvent when units are consumed.
fun consume_fuel_units(
    fuel: &mut Fuel,
    units_to_consume: u64,
    remaining_elapsed_ms: u64,
    current_time_ms: u64,
) {
    if (units_to_consume > 0) {
        assert!(option::is_some(&fuel.type_id), ETypeIdEmtpy);
        let fuel_type_id = *option::borrow(&fuel.type_id);
        fuel.quantity = fuel.quantity - units_to_consume;
        fuel.previous_cycle_elapsed_time = 0;
        fuel.burn_start_time = current_time_ms - remaining_elapsed_ms;
        event::emit(FuelUpdatedEvent {
            assembly_id: fuel.assembly_id,
            type_id: fuel_type_id,
            units_consumed: units_to_consume,
            remaining_quantity: fuel.quantity,
            is_burning: fuel.is_burning,
        });
    };
}

/// Calculates units to consume and remaining elapsed time based on total elapsed time and actual consumption rate.
/// Accounts for previous_cycle_elapsed_time from interrupted burn cycles.
fun calculate_units_to_consume(
    fuel: &Fuel,
    fuel_config: &FuelConfig,
    current_time_ms: u64,
): (u64, u64) {
    // If not burning or no burn start time, return 0
    if (!fuel.is_burning || fuel.burn_start_time == 0) {
        return (0, 0)
    };

    assert!(option::is_some(&fuel.type_id), ETypeIdEmtpy);
    let fuel_type_id = *option::borrow(&fuel.type_id);
    let fuel_efficiency = if (fuel_config.fuel_efficiency.contains(fuel_type_id)) {
        *fuel_config.fuel_efficiency.borrow(fuel_type_id)
    } else {
        abort EIncorrectFuelType
    };
    let actual_consumption_rate_ms = (fuel.burn_rate_in_ms * fuel_efficiency) / PERCENTAGE_DIVISOR;

    // Calculate elapsed time since burn started
    let elapsed_ms = if (current_time_ms > fuel.burn_start_time) {
        current_time_ms - fuel.burn_start_time
    } else {
        0
    };

    // Add previous cycle elapsed time to current elapsed time
    // This accounts for partial consumption from previous cycles
    let total_elapsed_ms = elapsed_ms + fuel.previous_cycle_elapsed_time;

    // Calculate units to consume and remaining elapsed time
    let units_to_consume = total_elapsed_ms / actual_consumption_rate_ms;
    let remaining_elapsed_ms = total_elapsed_ms % actual_consumption_rate_ms;

    (units_to_consume, remaining_elapsed_ms)
}

// === Init ===
fun init(ctx: &mut TxContext) {
    transfer::share_object(FuelConfig {
        id: object::new(ctx),
        fuel_efficiency: table::new(ctx),
    })
}

// === Test Functions ===
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun units_to_consume(
    fuel: &Fuel,
    fuel_config: &FuelConfig,
    current_time_ms: u64,
): (u64, u64) {
    calculate_units_to_consume(fuel, fuel_config, current_time_ms)
}

#[test_only]
public fun burn_start_time(fuel: &Fuel): u64 {
    fuel.burn_start_time
}

#[test_only]
public fun previous_cycle_elapsed_time(fuel: &Fuel): u64 {
    fuel.previous_cycle_elapsed_time
}

#[test_only]
public fun max_capacity(fuel: &Fuel): u64 {
    fuel.max_capacity
}

#[test_only]
public fun burn_rate_in_ms(fuel: &Fuel): u64 {
    fuel.burn_rate_in_ms
}
