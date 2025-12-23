// TODO: Add Fuel module to handle fuel operations like refueling, etc.
module world::fuel;

use sui::{clock::Clock, table::{Self, Table}};
use world::access::AdminCap;

// === Errors ===
#[error(code = 0)]
const ETypeIdEmtpy: vector<u8> = b"Fuel Type Id cannot be empty";
#[error(code = 1)]
const EInvalidFuelEfficiency: vector<u8> = b"Invalid Fuel Efficienct";
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
#[error(code = 14)]
const EConsumeFuelBeforeStop: vector<u8> = b"Call update before stop_burning";

// === Constants ===
const MIN_BURN_RATE_SECONDS: u64 = 60;
const MIN_FUEL_EFFICIENCY: u64 = 10;
const MAX_FUEL_EFFICIENCY: u64 = 100;
const PERCENTAGE_DIVISOR: u64 = 100;
const MILLISECONDS_PER_SECOND: u64 = 1000;

// === Structs ===
public struct FuelConfig has key {
    id: UID,
    fuel_efficiency: Table<u64, u64>,
}

public struct Fuel has store {
    assembly_id: ID,
    max_capacity: u64,
    burn_rate_in_ms: u64, // Stored in milliseconds for efficiency
    type_id: u64,
    volume: u64,
    quantity: u64,
    is_burning: bool,
    previous_cycle_elapsed_time: u64,
    burn_start_time: u64,
    last_updated: u64,
}

// === Events ===

// === Public Functions ===

// === View Functions ===
// get fuel efficiency by fuel type
public fun fuel_efficiency(fuel_config: &FuelConfig, fuel_type_id: u64): u64 {
    if (fuel_config.fuel_efficiency.contains(fuel_type_id)) {
        *fuel_config.fuel_efficiency.borrow(fuel_type_id)
    } else {
        abort EIncorrectFuelType
    }
}

public fun min_burn_rate(fuel: &Fuel): u64 {
    // Convert back to seconds for external API
    fuel.burn_rate_in_ms / MILLISECONDS_PER_SECOND
}

public fun quantity(fuel: &Fuel): u64 {
    fuel.quantity
}

public fun type_id(fuel: &Fuel): u64 {
    fuel.type_id
}

public fun volume(fuel: &Fuel): u64 {
    fuel.volume
}

public fun is_burning(fuel: &Fuel): bool {
    fuel.is_burning
}

// fun to check if it has enough fuel to keep running at current time in ms
public fun has_enough_fuel(fuel: &Fuel, fuel_config: &FuelConfig, clock: &Clock): bool {
    if (!fuel.is_burning) return false;

    let (units_to_consume, _) = calculate_units_to_consume(
        fuel,
        fuel_config,
        clock.timestamp_ms(),
    );

    fuel.quantity >= units_to_consume
}

// === Admin Functions ===
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
}

public fun remove_fuel_efficiency(fuel_config: &mut FuelConfig, _: &AdminCap, fuel_type_id: u64) {
    assert!(fuel_type_id != 0, ETypeIdEmtpy);
    fuel_config.fuel_efficiency.remove(fuel_type_id);
}

// === Package Functions ===
// create fuel object for the parent assembly and assembly_id set fuel max capacity, burn rate in seconds
// Converts burn_rate_in_seconds to milliseconds and stores it for efficiency
public(package) fun create(assembly_id: ID, max_capacity: u64, burn_rate_in_seconds: u64): Fuel {
    assert!(max_capacity > 0, EInvalidMaxCapacity);
    assert!(burn_rate_in_seconds >= MIN_BURN_RATE_SECONDS, EInvalidBurnRate);
    // Convert to milliseconds once at creation time
    let burn_rate_in_ms = burn_rate_in_seconds * MILLISECONDS_PER_SECOND;
    Fuel {
        assembly_id,
        max_capacity,
        burn_rate_in_ms,
        type_id: 0,
        volume: 0,
        quantity: 0,
        is_burning: false,
        previous_cycle_elapsed_time: 0,
        burn_start_time: 0,
        last_updated: 0,
    }
}

public(package) fun deposit(
    fuel: &mut Fuel,
    type_id: u64,
    volume: u64,
    quantity: u64,
    clock: &Clock,
) {
    assert!(quantity > 0, EInvalidDepositQuantity);
    assert!(volume > 0, EInvalidVolume);
    assert!(type_id != 0, ETypeIdEmtpy);

    // Initialize or verify fuel type matches
    if (fuel.type_id == 0 || fuel.quantity == 0) {
        if (fuel.is_burning) {
            // reset time tracking - the burning will continue with new fuel
            fuel.burn_start_time = clock.timestamp_ms();
            fuel.previous_cycle_elapsed_time = 0;
        } else {
            fuel.burn_start_time = 0;
            fuel.previous_cycle_elapsed_time = 0;
        };
        fuel.type_id = type_id;
        fuel.volume = volume;
    } else {
        assert!(fuel.type_id == type_id, EFuelTypeMismatch);
    };

    let new_quantity = fuel.quantity + quantity;
    assert!(fuel.volume * new_quantity <= fuel.max_capacity, EFuelCapacityExceeded);
    fuel.quantity = new_quantity;
}

// withdraw fuel by owner, decrease the fuel quantity if it has enough fuel
public(package) fun withdraw(fuel: &mut Fuel, quantity: u64) {
    assert!(quantity > 0, EInvalidWithdrawQuantity);
    assert!(fuel.quantity >= quantity, EInsufficientFuel);
    fuel.quantity = fuel.quantity - quantity;
}

public(package) fun start_burning(fuel: &mut Fuel, clock: &Clock) {
    assert!(!fuel.is_burning, EFuelAlreadyBurning);
    assert!(fuel.quantity > 0 || fuel.previous_cycle_elapsed_time > 0, ENoFuelToBurn);
    assert!(fuel.type_id != 0, ETypeIdEmtpy);

    // todo : should we check if last_updated is the current block ?

    fuel.is_burning = true;
    fuel.burn_start_time = clock.timestamp_ms();
    if (fuel.quantity != 0) {
        fuel.quantity = fuel.quantity - 1; // Consume 1 unit to start the clock
    }
}

// stop burning fuel
// check if its burning, then
// set the burn start time to 0
// and update the previous cycle elapsed time if the fuel has not reached its burn rate
// Uses calculate_units_to_consume to avoid code duplication
public(package) fun stop_burning(fuel: &mut Fuel, fuel_config: &FuelConfig, clock: &Clock) {
    assert!(fuel.is_burning, EFuelNotBurning);
    // todo : should we check if last_updated is the current block ?

    let current_time_ms = clock.timestamp_ms();
    let (units_to_consume, remaining_elapsed_ms) = calculate_units_to_consume(
        fuel,
        fuel_config,
        current_time_ms,
    );

    assert!(units_to_consume == 0, EConsumeFuelBeforeStop);

    // Update previous_cycle_elapsed_time with remaining time for next cycle
    fuel.previous_cycle_elapsed_time = remaining_elapsed_ms;
    fuel.burn_start_time = 0;
    fuel.is_burning = false;
}

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

    if (fuel.quantity == 0) {
        handle_empty_fuel_state(
            fuel,
            units_to_consume,
            remaining_elapsed_ms,
            current_time_ms,
        );
        return
    };

    consume_fuel_units(
        fuel,
        units_to_consume,
        remaining_elapsed_ms,
        current_time_ms,
    );

    fuel.last_updated = current_time_ms;
}

// === Private Functions ===
fun handle_empty_fuel_state(
    fuel: &mut Fuel,
    units_to_consume: u64,
    remaining_elapsed_ms: u64,
    current_time_ms: u64,
) {
    // Stop burning if trying to consume units or last unit finished
    if (units_to_consume > 0 || remaining_elapsed_ms == 0) {
        fuel.is_burning = false;
        fuel.previous_cycle_elapsed_time = 0;
        fuel.burn_start_time = 0;
    } else {
        // Last unit still burning (has remaining elapsed time)
        fuel.burn_start_time = current_time_ms - remaining_elapsed_ms;
        fuel.previous_cycle_elapsed_time = 0;
    };
    fuel.last_updated = current_time_ms;
}

fun consume_fuel_units(
    fuel: &mut Fuel,
    units_to_consume: u64,
    remaining_elapsed_ms: u64,
    current_time_ms: u64,
) {
    let actual_units_to_consume = if (units_to_consume > fuel.quantity) {
        fuel.quantity
    } else {
        units_to_consume
    };

    if (actual_units_to_consume > 0) {
        fuel.quantity = fuel.quantity - actual_units_to_consume;
        fuel.previous_cycle_elapsed_time = 0;
        update_burn_start_time_after_consumption(
            fuel,
            remaining_elapsed_ms,
            current_time_ms,
        );
    };
}

fun update_burn_start_time_after_consumption(
    fuel: &mut Fuel,
    remaining_elapsed_ms: u64,
    current_time_ms: u64,
) {
    if (fuel.quantity == 0) {
        if (remaining_elapsed_ms == 0) {
            // Consumed exactly the right amount, start burning the last unit
            fuel.burn_start_time = current_time_ms;
        } else {
            // Last unit still burning with remaining time
            fuel.burn_start_time = current_time_ms - remaining_elapsed_ms;
        };
    } else {
        // Still have fuel, update burn_start_time normally
        fuel.burn_start_time = current_time_ms - remaining_elapsed_ms;
    };
}

fun calculate_units_to_consume(
    fuel: &Fuel,
    fuel_config: &FuelConfig,
    current_time_ms: u64,
): (u64, u64) {
    // If not burning or no burn start time, return 0
    if (!fuel.is_burning || fuel.burn_start_time == 0) {
        return (0, 0)
    };

    let fuel_efficiency = if (fuel_config.fuel_efficiency.contains(fuel.type_id)) {
        *fuel_config.fuel_efficiency.borrow(fuel.type_id)
    } else {
        abort EIncorrectFuelType
    };
    // Efficiency is validated when set, so we can safely calculate
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
