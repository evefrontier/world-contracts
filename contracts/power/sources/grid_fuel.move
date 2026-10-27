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
#[error(code = 7)]
const EWrongTenant: vector<u8> = b"Fuel sources can only move between entities of the same tenant";

// === Structs ===

/// Fuel carried out of a grid by `uninstall`. Holds the source it left so a
/// later burn can name that source.
public struct FuelLoad {
    entity_id: ID,
    fuel_source_id: u64,
    amount: u64,
    impulse: u64,
    containment_burden: u64,
}

// === Events ===

public struct FuelSourceAttached has copy, drop {
    entity_id: ID,
    fuel_source_id: u64,
    capacity: u64,
}

/// Fuel carried out of the grid.
public struct FuelSourceDetached has copy, drop {
    entity_id: ID,
    fuel_source_id: u64,
    amount: u64,
    impulse: u64,
    containment_burden: u64,
}

/// A Fuel source was installed already holding this much fuel.
public struct FuelLoaded has copy, drop {
    entity_id: ID,
    fuel_source_id: u64,
    amount: u64,
    impulse: u64,
    containment_burden: u64,
}

public struct FuelLoadBurned has copy, drop {
    entity_id: ID,
    fuel_source_id: u64,
    amount: u64,
    impulse: u64,
    containment_burden: u64,
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
    grid.settle(clock);
    grid.connect_fuel_source(component_id, capacity);
    grid.regrant(entity_id);
    event::emit(FuelSourceAttached { entity_id, fuel_source_id: component_id, capacity });
    req
}

/// Install a Fuel source holding `load`, blended into the pool. Admin-gated.
/// Aborts if the pool would exceed the grid's fuel capacity.
public fun install_with_fuel(
    entity: &mut Entity,
    fuel_source_id: u64,
    name: Option<String>,
    capacity: u64,
    load: FuelLoad,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    // TODO: the fuel pool logic will be removed with the fuel refactor
    let FuelLoad {
        entity_id: _,
        fuel_source_id: _,
        amount,
        impulse,
        containment_burden,
    } = load;
    let req = install(entity, fuel_source_id, name, capacity, clock, ctx);
    if (amount > 0) {
        let entity_id = entity.id();
        let grid = power_grid::grid_mut(entity);
        let quantity = grid.fuel_quantity_at_last_settled() + amount;
        assert!(quantity <= grid.fuel_capacity(), EFuelOverCapacity);
        grid.blend_in_fuel(amount, impulse, containment_burden);
        grid.regrant(entity_id);
        event::emit(FuelLoaded {
            entity_id,
            fuel_source_id,
            amount,
            impulse,
            containment_burden,
        });
    };
    req
}

/// Uninstall a Fuel source and remove its capacity. It takes its share of the
/// pool, the fuel times its share of the capacity, at the pool's stats; the
/// last source takes all that is left. Returns that fuel, which
/// `install_with_fuel` accepts. Admin-gated.
public fun uninstall(
    entity: &mut Entity,
    fuel_source_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Request, FuelLoad) {
    // TODO: the fuel pool logic will be removed with the fuel refactor
    assert!(power_grid::is_fuel_source_connected(entity, fuel_source_id), EFuelSourceNotConnected);
    let entity_id = entity.id();
    let req = fuel::uninstall(entity, fuel_source_id, ctx);
    let grid = power_grid::grid_mut(entity);
    grid.settle(clock);
    let capacity = grid.fuel_source_capacity(fuel_source_id);
    let load = FuelLoad {
        entity_id,
        fuel_source_id,
        amount: share_of(grid.fuel_quantity_at_last_settled(), capacity, grid.fuel_capacity()),
        impulse: grid.fuel_impulse(),
        containment_burden: grid.fuel_containment_burden(),
    };
    grid.remove_fuel(load.amount);
    grid.disconnect_fuel_source(fuel_source_id);
    grid.regrant(entity_id);
    event::emit(FuelSourceDetached {
        entity_id,
        fuel_source_id,
        amount: load.amount,
        impulse: load.impulse,
        containment_burden: load.containment_burden,
    });
    (req, load)
}

/// Move Fuel source `fuel_source_id` from `from` to `to` with its fuel: `uninstall`
/// then `install_with_fuel`. Admin-gated: returns `from`'s request, then `to`'s.
public fun migrate(
    from: &mut Entity,
    to: &mut Entity,
    fuel_source_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Request, Request) {
    assert!(from.key().tenant() == to.key().tenant(), EWrongTenant);
    let capacity = power_grid::power_grid(from).fuel_source_capacity(fuel_source_id);
    let name = fuel::name(from, fuel_source_id);
    let (from_req, load) = uninstall(from, fuel_source_id, clock, ctx);
    let to_req = install_with_fuel(to, fuel_source_id, name, capacity, load, clock, ctx);
    (from_req, to_req)
}

/// Destroy a fuel load that is not reinstalled.
public fun burn_fuel_load(load: FuelLoad) {
    let FuelLoad { entity_id, fuel_source_id, amount, impulse, containment_burden } = load;
    event::emit(FuelLoadBurned {
        entity_id,
        fuel_source_id,
        amount,
        impulse,
        containment_burden,
    });
}

// TODO: an `Item` to fuel path once inventory can connect to the fuel source.
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
    grid.settle(clock);
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

/// `quantity * part / whole`, rounded down. All of it when `part` is the whole.
fun share_of(quantity: u64, part: u64, whole: u64): u64 {
    if (part >= whole) return quantity;
    ((quantity as u128) * (part as u128) / (whole as u128)) as u64
}

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

// === View Functions ===

public fun load_entity_id(load: &FuelLoad): ID {
    load.entity_id
}

public fun load_fuel_source_id(load: &FuelLoad): u64 {
    load.fuel_source_id
}

public fun load_amount(load: &FuelLoad): u64 {
    load.amount
}

public fun load_impulse(load: &FuelLoad): u64 {
    load.impulse
}

public fun load_containment_burden(load: &FuelLoad): u64 {
    load.containment_burden
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

/// `(entity_id, fuel_source_id, capacity)`.
#[test_only]
public fun fuel_source_attached_fields(fuel_source_attached: &FuelSourceAttached): (ID, u64, u64) {
    (
        fuel_source_attached.entity_id,
        fuel_source_attached.fuel_source_id,
        fuel_source_attached.capacity,
    )
}

/// `(entity_id, fuel_source_id, amount, impulse, containment_burden)`.
#[test_only]
public fun fuel_load_burned_fields(burned: &FuelLoadBurned): (ID, u64, u64, u64, u64) {
    (
        burned.entity_id,
        burned.fuel_source_id,
        burned.amount,
        burned.impulse,
        burned.containment_burden,
    )
}

/// `(entity_id, fuel_source_id, amount, impulse, containment_burden)`.
#[test_only]
public fun fuel_source_detached_fields(
    fuel_source_detached: &FuelSourceDetached,
): (ID, u64, u64, u64, u64) {
    (
        fuel_source_detached.entity_id,
        fuel_source_detached.fuel_source_id,
        fuel_source_detached.amount,
        fuel_source_detached.impulse,
        fuel_source_detached.containment_burden,
    )
}
