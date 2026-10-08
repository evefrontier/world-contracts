/// Fuel sources and deposits. Borrows the grid and asks `power_grid` to write
/// the pool. Does not touch grid fields.
module power::grid_fuel;

use core::{access_cap, admin_service, entity::Entity, request::Request, requirement::Requirement};
use power::{fuel, power_grid};
use sui::{bcs, clock::Clock, event};

// === Errors ===

#[error(code = 0)]
const EFuelSourceAlreadyRegistered: vector<u8> =
    b"Fuel source is already registered with this power grid";
#[error(code = 1)]
const EFuelSourceStillRegistered: vector<u8> =
    b"Fuel source must be unregistered from the power grid before uninstall";
#[error(code = 2)]
const EFuelOverCapacity: vector<u8> = b"Fuel quantity would exceed the grid's fuel capacity";
#[error(code = 3)]
const EZeroFuel: vector<u8> = b"Fuel amount must be greater than zero";
#[error(code = 4)]
const EFuelTypeNotAllowed: vector<u8> = b"Fuel type is not allowed by the requirement";
#[error(code = 5)]
const EBurdenAboveMax: vector<u8> = b"Fuel containment burden is above the requirement";
#[error(code = 6)]
const EFuelAmountBelowMin: vector<u8> = b"Fuel amount is below the requirement";
#[error(code = 7)]
const EFuelAmountAboveMax: vector<u8> = b"Fuel amount is above the requirement";

// === Events ===

public struct FuelSourceRegistered has copy, drop {
    entity_id: ID,
    fuel_id: u64,
    capacity: u64,
}

public struct FuelSourceUnregistered has copy, drop {
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

/// Register an installed Fuel source with its `capacity` (units at `SCALE`). Admin-only.
public fun register_fuel_source(
    entity: &mut Entity,
    req: &mut Request,
    fuel_id: u64,
    capacity: u64,
    clock: &Clock,
) {
    fuel::assert_installed(entity, fuel_id);
    let entity_id = entity.id();
    let (_requirement, mut frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::manage_fuel_permit(),
    );
    assert!(!power_grid::fuel_sources(grid).contains(&fuel_id), EFuelSourceAlreadyRegistered);
    power_grid::settle(grid, entity_id, clock);
    power_grid::insert_fuel_source(grid, fuel_id, capacity);
    event::emit(FuelSourceRegistered { entity_id, fuel_id, capacity });
    frame.require(admin_service::admin_requirement());
    req.enqueue(frame);
}

/// Remove a Fuel source from the grid. Aborts if the settled fuel would not
/// fit the reduced capacity. Admin-only.
public fun unregister_fuel_source(
    entity: &mut Entity,
    req: &mut Request,
    fuel_id: u64,
    clock: &Clock,
) {
    let entity_id = entity.id();
    let (_requirement, mut frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::manage_fuel_permit(),
    );
    power_grid::assert_fuel_source_registered(grid, fuel_id);
    power_grid::settle(grid, entity_id, clock);
    let remaining =
        power_grid::fuel_capacity(grid) - power_grid::fuel_source_capacity(grid, fuel_id);
    assert!(power_grid::settled_fuel_quantity(grid) <= remaining, EFuelOverCapacity);
    power_grid::remove_fuel_source(grid, fuel_id);
    event::emit(FuelSourceUnregistered { entity_id, fuel_id });
    frame.require(admin_service::admin_requirement());
    req.enqueue(frame);
}

/// Uninstall an unregistered Fuel source. Admin-gated.
public fun uninstall_fuel_source(entity: &mut Entity, fuel_id: u64, ctx: &mut TxContext): Request {
    assert!(!power_grid::is_fuel_source_registered(entity, fuel_id), EFuelSourceStillRegistered);
    fuel::uninstall(entity, fuel_id, ctx)
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
    power_grid::settle(grid, entity_id, clock);
    let old_quantity = power_grid::settled_fuel_quantity(grid);
    assert!(old_quantity + amount <= power_grid::fuel_capacity(grid), EFuelOverCapacity);
    power_grid::blend_in_fuel(grid, amount, impulse, containment_burden);
    event::emit(FuelAdded {
        entity_id,
        fuel_type,
        amount,
        resulting_quantity: power_grid::settled_fuel_quantity(grid),
        resulting_impulse: power_grid::fuel_impulse(grid),
        resulting_containment_burden: power_grid::fuel_containment_burden(grid),
    });
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
