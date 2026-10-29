/// Fuel bay install, uninstall, online state and deposits. A fuel bay connects
/// to the grid inside its install, offline and holding its own fuel. Borrows the
/// grid and asks `power_grid` to write the bay.
module power::grid_fuel;

use core::{access_cap, admin_service, entity::Entity, request::Request, requirement::Requirement};
use power::{fuel_bay, power_grid::{Self, Fuel}};
use std::string::String;
use sui::{bcs, clock::Clock, event};

// === Errors ===

#[error(code = 0)]
const EFuelOverCapacity: vector<u8> = b"Fuel amount would exceed the fuel bay's capacity";
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
const EFuelBayNotConnected: vector<u8> = b"Fuel bay is not connected to this power grid";
#[error(code = 7)]
const EWrongTenant: vector<u8> = b"Fuel bays can only move between entities of the same tenant";
#[error(code = 8)]
const EFuelBayAlreadyOnline: vector<u8> = b"Fuel bay is already online";
#[error(code = 9)]
const EFuelBayAlreadyOffline: vector<u8> = b"Fuel bay is already offline";

// === Structs ===

/// A fuel bay's exact fuel, carried out of a grid by `uninstall`.
public struct FuelLoad {
    entity_id: ID,
    fuel_bay_id: u64,
    fuel: Fuel,
}

// === Events ===

public struct FuelBayAttached has copy, drop {
    entity_id: ID,
    fuel_bay_id: u64,
    capacity: u64,
}

/// A fuel bay left the grid carrying this fuel.
public struct FuelBayDetached has copy, drop {
    entity_id: ID,
    fuel_bay_id: u64,
    amount: u64,
    impulse: u64,
    containment_burden: u64,
    volatility: u64,
}

/// A fuel bay was installed already holding this fuel.
public struct FuelLoaded has copy, drop {
    entity_id: ID,
    fuel_bay_id: u64,
    amount: u64,
    impulse: u64,
    containment_burden: u64,
    volatility: u64,
}

public struct FuelLoadBurned has copy, drop {
    entity_id: ID,
    fuel_bay_id: u64,
    amount: u64,
    impulse: u64,
    containment_burden: u64,
    volatility: u64,
}

public struct FuelBayToggled has copy, drop {
    entity_id: ID,
    fuel_bay_id: u64,
    online: bool,
}

/// Fuel was loaded into a bay; the `resulting_*` values are that bay after blending.
/// `amount` is plain as deposited; `resulting_amount` is at `SCALE`.
public struct FuelAdded has copy, drop {
    entity_id: ID,
    fuel_bay_id: u64,
    fuel_type: u64,
    amount: u64,
    resulting_amount: u64,
    resulting_impulse: u64,
    resulting_containment_burden: u64,
    resulting_volatility: u64,
}

// === Public Functions ===

/// Install an empty fuel bay of `capacity` plain units, offline. Admin-gated.
public fun install(
    entity: &mut Entity,
    component_id: u64,
    name: Option<String>,
    capacity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    connect(entity, component_id, name, capacity, power_grid::empty_fuel(), clock, ctx)
}

/// Install a fuel bay holding `load`, offline. Admin-gated. Aborts if the load
/// exceeds `capacity`.
public fun install_with_fuel(
    entity: &mut Entity,
    fuel_bay_id: u64,
    name: Option<String>,
    capacity: u64,
    load: FuelLoad,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    let FuelLoad { entity_id: _, fuel_bay_id: _, fuel } = load;
    let req = connect(entity, fuel_bay_id, name, capacity, fuel, clock, ctx);
    if (fuel.quantity() > 0) {
        event::emit(FuelLoaded {
            entity_id: entity.id(),
            fuel_bay_id,
            amount: fuel.quantity(),
            impulse: fuel.impulse(),
            containment_burden: fuel.containment_burden(),
            volatility: fuel.volatility(),
        });
    };
    req
}

/// Uninstall a fuel bay. Returns its exact fuel, which `install_with_fuel`
/// accepts. Admin-gated.
public fun uninstall(
    entity: &mut Entity,
    fuel_bay_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Request, FuelLoad) {
    assert!(power_grid::is_fuel_bay_connected(entity, fuel_bay_id), EFuelBayNotConnected);
    let entity_id = entity.id();
    let req = fuel_bay::uninstall(entity, fuel_bay_id, ctx);
    let grid = power_grid::grid_mut(entity);
    grid.settle(clock);
    let fuel = grid.disconnect_fuel_bay(fuel_bay_id);
    grid.regrant(entity_id);
    event::emit(FuelBayDetached {
        entity_id,
        fuel_bay_id,
        amount: fuel.quantity(),
        impulse: fuel.impulse(),
        containment_burden: fuel.containment_burden(),
        volatility: fuel.volatility(),
    });
    (req, FuelLoad { entity_id, fuel_bay_id, fuel })
}

/// Move fuel bay `fuel_bay_id` from `from` to `to` with its fuel: `uninstall`
/// then `install_with_fuel`. It arrives offline. Admin-gated: returns `from`'s
/// request, then `to`'s.
public fun migrate(
    from: &mut Entity,
    to: &mut Entity,
    fuel_bay_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Request, Request) {
    assert!(from.key().tenant() == to.key().tenant(), EWrongTenant);
    let capacity = power_grid::fuel_bay_state(from, fuel_bay_id).capacity();
    let name = fuel_bay::name(from, fuel_bay_id);
    let (from_req, load) = uninstall(from, fuel_bay_id, clock, ctx);
    let to_req = install_with_fuel(to, fuel_bay_id, name, capacity, load, clock, ctx);
    (from_req, to_req)
}

/// Destroy a fuel load that is not reinstalled.
public fun burn_fuel_load(load: FuelLoad) {
    let FuelLoad { entity_id, fuel_bay_id, fuel } = load;
    event::emit(FuelLoadBurned {
        entity_id,
        fuel_bay_id,
        amount: fuel.quantity(),
        impulse: fuel.impulse(),
        containment_burden: fuel.containment_burden(),
        volatility: fuel.volatility(),
    });
}

/// Bring a fuel bay online or offline. An offline bay keeps its fuel and feeds
/// nothing. Settles first, because burn depends on which bays feed the grid.
public fun set_fuel_bay(
    entity: &mut Entity,
    req: &mut Request,
    fuel_bay_id: u64,
    online: bool,
    clock: &Clock,
) {
    let entity_id = entity.id();
    let (_requirement, mut frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::operate_grid_permit(),
    );
    assert!(power_grid::bays(grid).contains(&fuel_bay_id), EFuelBayNotConnected);
    grid.settle(clock);
    let already_online = grid.bay_state(fuel_bay_id).bay_online();
    if (online) assert!(!already_online, EFuelBayAlreadyOnline)
    else assert!(already_online, EFuelBayAlreadyOffline);
    grid.set_bay_online(fuel_bay_id, online);
    event::emit(FuelBayToggled { entity_id, fuel_bay_id, online });
    grid.regrant(entity_id);
    frame.require(access_cap::owner_requirement());
    req.enqueue(frame);
}

// TODO: an `Item` to fuel path once inventory can connect to the fuel bay.
/// Load `amount` of fuel into one bay and blend its stats by weighted average,
/// if it meets the owner's `FuelRequirement`. All values plain, supplied by the
/// game server; the bay stores the amount at `SCALE`.
public fun deposit_fuel(
    entity: &mut Entity,
    req: &mut Request,
    fuel_bay_id: u64,
    fuel_type: u64,
    amount: u64,
    impulse: u64,
    containment_burden: u64,
    volatility: u64,
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
    assert!(power_grid::bays(grid).contains(&fuel_bay_id), EFuelBayNotConnected);
    grid.settle(clock);
    let bay = grid.bay_state(fuel_bay_id);
    let scaled = (amount as u128) * (power_grid::scale() as u128);
    assert_fits(bay.capacity(), (bay.fuel().quantity() as u128) + scaled);
    grid.blend_into_bay(
        fuel_bay_id,
        power_grid::new_fuel(scaled as u64, impulse, containment_burden, volatility),
    );
    let fuel = grid.bay_state(fuel_bay_id).fuel();
    event::emit(FuelAdded {
        entity_id,
        fuel_bay_id,
        fuel_type,
        amount,
        resulting_amount: fuel.quantity(),
        resulting_impulse: fuel.impulse(),
        resulting_containment_burden: fuel.containment_burden(),
        resulting_volatility: fuel.volatility(),
    });
    grid.regrant(entity_id);
    frame.require(access_cap::owner_requirement());
    frame.require(admin_service::sponsor_requirement());
    req.enqueue(frame);
}

// === View Functions ===

public fun load_entity_id(load: &FuelLoad): ID {
    load.entity_id
}

public fun load_fuel_bay_id(load: &FuelLoad): u64 {
    load.fuel_bay_id
}

public fun load_fuel(load: &FuelLoad): Fuel {
    load.fuel
}

public fun load_amount(load: &FuelLoad): u64 {
    load.fuel.quantity()
}

public fun load_impulse(load: &FuelLoad): u64 {
    load.fuel.impulse()
}

public fun load_containment_burden(load: &FuelLoad): u64 {
    load.fuel.containment_burden()
}

public fun load_volatility(load: &FuelLoad): u64 {
    load.fuel.volatility()
}

// === Private Functions ===

/// Install the bay component and connect it to the grid holding `fuel`, offline.
fun connect(
    entity: &mut Entity,
    fuel_bay_id: u64,
    name: Option<String>,
    capacity: u64,
    fuel: Fuel,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    assert_fits(capacity, fuel.quantity() as u128);
    let entity_id = entity.id();
    let req = fuel_bay::install(entity, fuel_bay_id, name, ctx);
    let grid = power_grid::grid_mut(entity);
    grid.settle(clock);
    grid.connect_fuel_bay(fuel_bay_id, capacity, fuel);
    grid.regrant(entity_id);
    event::emit(FuelBayAttached { entity_id, fuel_bay_id, capacity });
    req
}

/// Abort unless `amount` (at `SCALE`) fits a bay of `capacity` plain units.
fun assert_fits(capacity: u64, amount: u128) {
    let room = (capacity as u128) * (power_grid::scale() as u128);
    assert!(amount <= room, EFuelOverCapacity);
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

// === Test Functions ===

/// `(entity_id, fuel_bay_id, fuel_type, amount, resulting_amount, resulting_impulse,
/// resulting_containment_burden, resulting_volatility)`.
#[test_only]
public fun fuel_added_fields(added: &FuelAdded): (ID, u64, u64, u64, u64, u64, u64, u64) {
    (
        added.entity_id,
        added.fuel_bay_id,
        added.fuel_type,
        added.amount,
        added.resulting_amount,
        added.resulting_impulse,
        added.resulting_containment_burden,
        added.resulting_volatility,
    )
}

/// `(entity_id, fuel_bay_id, capacity)`.
#[test_only]
public fun fuel_bay_attached_fields(attached: &FuelBayAttached): (ID, u64, u64) {
    (attached.entity_id, attached.fuel_bay_id, attached.capacity)
}

/// `(entity_id, fuel_bay_id, online)`.
#[test_only]
public fun fuel_bay_toggled_fields(toggled: &FuelBayToggled): (ID, u64, bool) {
    (toggled.entity_id, toggled.fuel_bay_id, toggled.online)
}

/// `(entity_id, fuel_bay_id, amount, impulse, containment_burden, volatility)`.
#[test_only]
public fun fuel_load_burned_fields(burned: &FuelLoadBurned): (ID, u64, u64, u64, u64, u64) {
    (
        burned.entity_id,
        burned.fuel_bay_id,
        burned.amount,
        burned.impulse,
        burned.containment_burden,
        burned.volatility,
    )
}

/// `(entity_id, fuel_bay_id, amount, impulse, containment_burden, volatility)`.
#[test_only]
public fun fuel_bay_detached_fields(detached: &FuelBayDetached): (ID, u64, u64, u64, u64, u64) {
    (
        detached.entity_id,
        detached.fuel_bay_id,
        detached.amount,
        detached.impulse,
        detached.containment_burden,
        detached.volatility,
    )
}
