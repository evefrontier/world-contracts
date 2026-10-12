/// Fuel source install, uninstall and deposits. A Fuel source adds its capacity
/// to the grid inside its install
/// Borrows the grid and asks `power_grid` to write the pool.
module power::grid_fuel;

use core::{access_cap, admin_service, entity::Entity, request::Request, requirement::Requirement};
use power::{fuel, power_grid};
use std::string::String;
use sui::{bcs, clock::Clock, event};

// === Errors ===

#[error(code = 0)]
const EFuelOverCapacity: vector<u8> = b"Fuel quantity would exceed the grid's fuel capacity";
#[error(code = 1)]
const EZeroFuel: vector<u8> = b"Fuel amount must be greater than zero";
#[error(code = 2)]
const EFuelTypeNotAllowed: vector<u8> = b"Fuel type is not allowed by the requirement";
#[error(code = 3)]
const EBurdenAboveMax: vector<u8> = b"Fuel containment burden is above the requirement";
#[error(code = 4)]
const EFuelAmountBelowMin: vector<u8> = b"Fuel amount is below the requirement";
#[error(code = 5)]
const EFuelAmountAboveMax: vector<u8> = b"Fuel amount is above the requirement";
#[error(code = 6)]
const EFuelSourceNotConnected: vector<u8> = b"Fuel source is not connected to this power grid";

// === Events ===

public struct FuelSourceConnected has copy, drop {
    entity_id: ID,
    fuel_id: u64,
    capacity: u64,
}

public struct FuelSourceDisconnected has copy, drop {
    entity_id: ID,
    fuel_id: u64,
}

/// Fuel was deposited; the `resulting_*` values are the pool after blending.
public struct FuelAdded has copy, drop {
    entity_id: ID,
    fuel_type: u64,
    amount: u64,
    resulting_quantity: u64,
    resulting_impulse: u64,
    resulting_containment_burden: u64,
}

// === Public Functions ===

/// Install a Fuel source and add its `capacity` (units at `SCALE`) to the grid.
/// Admin-gated.
public fun install(
    entity: &mut Entity,
    component_id: u64,
    name: Option<String>,
    capacity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    let entity_id = entity.id();
    let req = fuel::install(entity, component_id, name, ctx);
    let grid = power_grid::grid_mut(entity);
    grid.settle(entity_id, clock);
    grid.connect_fuel_source(component_id, capacity);
    event::emit(FuelSourceConnected { entity_id, fuel_id: component_id, capacity });
    req
}

/// Uninstall a Fuel source and remove its capacity. Aborts if the settled fuel
/// would not fit the reduced capacity. Admin-gated.
public fun uninstall(
    entity: &mut Entity,
    fuel_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    assert!(power_grid::is_fuel_source_connected(entity, fuel_id), EFuelSourceNotConnected);
    let entity_id = entity.id();
    let req = fuel::uninstall(entity, fuel_id, ctx);
    let grid = power_grid::grid_mut(entity);
    grid.settle(entity_id, clock);
    let remaining = grid.fuel_capacity() - grid.fuel_source_capacity(fuel_id);
    assert!(grid.fuel_quantity_at_last_settled() <= remaining, EFuelOverCapacity);
    grid.disconnect_fuel_source(fuel_id);
    event::emit(FuelSourceDisconnected { entity_id, fuel_id });
    req
}

// TODO: an `Item` to fuel path once inventory can connect to the fuel bay.
/// Bridge `amount` of fuel into the pool and blend its stats by weighted
/// average, if it meets the owner's `FuelRequirement`. All values at `SCALE`,
/// supplied by the game server.
public fun deposit_fuel(
    entity: &mut Entity,
    req: &mut Request,
    fuel_type: u64,
    amount: u64,
    impulse: u64,
    containment_burden: u64,
    clock: &Clock,
) {
    let entity_id = entity.id();
    let (requirement, mut frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::deposit_fuel_permit(),
    );
    assert!(amount > 0, EZeroFuel);
    enforce_fuel(&requirement, fuel_type, amount, impulse, containment_burden);
    grid.settle(entity_id, clock);
    let old_quantity = grid.fuel_quantity_at_last_settled();
    assert!(old_quantity + amount <= grid.fuel_capacity(), EFuelOverCapacity);
    grid.blend_in_fuel(amount, impulse, containment_burden);
    event::emit(FuelAdded {
        entity_id,
        fuel_type,
        amount,
        resulting_quantity: grid.fuel_quantity_at_last_settled(),
        resulting_impulse: grid.fuel_impulse(),
        resulting_containment_burden: grid.fuel_containment_burden(),
    });
    grid.regrant(entity_id);
    frame.require(access_cap::owner_requirement());
    frame.require(admin_service::sponsor_requirement());
    req.enqueue(frame);
}

// === Private Functions ===

/// Abort if a deposit breaks a `FuelRequirement`. Mirrors its field order.
fun enforce_fuel(
    requirement: &Requirement,
    fuel_type: u64,
    amount: u64,
    impulse: u64,
    containment_burden: u64,
) {
    let mut encoded = bcs::new(requirement.data());
    let fuel_types = encoded.peel_vec_u64();
    let min_impulse = encoded.peel_option_u64();
    let max_containment_burden = encoded.peel_option_u64();
    let min_amount = encoded.peel_option_u64();
    let max_amount = encoded.peel_option_u64();
    assert!(fuel_types.is_empty() || fuel_types.contains(&fuel_type), EFuelTypeNotAllowed);
    min_impulse.do!(|min| power_grid::assert_impulse_at_least(impulse, min));
    max_containment_burden.do!(|max| assert!(containment_burden <= max, EBurdenAboveMax));
    min_amount.do!(|min| assert!(amount >= min, EFuelAmountBelowMin));
    max_amount.do!(|max| assert!(amount <= max, EFuelAmountAboveMax));
}

// === Test Functions ===

/// `(entity_id, fuel_type, amount, resulting_quantity, resulting_impulse, resulting_containment_burden)`.
#[test_only]
public fun fuel_added_fields(added: &FuelAdded): (ID, u64, u64, u64, u64, u64) {
    (
        added.entity_id,
        added.fuel_type,
        added.amount,
        added.resulting_quantity,
        added.resulting_impulse,
        added.resulting_containment_burden,
    )
}

/// `(entity_id, fuel_id, capacity)`.
#[test_only]
public fun fuel_source_connected_fields(
    fuel_source_connected: &FuelSourceConnected,
): (ID, u64, u64) {
    (fuel_source_connected.entity_id, fuel_source_connected.fuel_id, fuel_source_connected.capacity)
}

/// `(entity_id, fuel_id)`.
#[test_only]
public fun fuel_source_disconnected_fields(
    fuel_source_disconnected: &FuelSourceDisconnected,
): (ID, u64) {
    (fuel_source_disconnected.entity_id, fuel_source_disconnected.fuel_id)
}
