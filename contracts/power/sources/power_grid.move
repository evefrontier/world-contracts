/// Power grid component installed on an `Entity`: one per Creation, at a
/// well-known component slot. Pools the capacity of its Generators and the fuel
/// of its Fuel components, and grants Firm or Elastic draws to connected modules.
///
/// Power On/Off is the Creation-level master switch. Off treats capacity as
/// zero; Both are requirements the owner bundles into an action
///
/// See `docs/adr/0005-onchain-power-network.md`.
module power::power_grid;

use core::{
    component::{Self, Component},
    entity::Entity,
    request::{Request, Frame},
    requirement::{Self, Requirement}
};
use std::{internal::Permit, string::{Self, String}};
use sui::{clock::Clock, event, vec_map::{Self, VecMap}, vec_set::{Self, VecSet}};

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"PowerGrid component version does not match the package version";
#[error(code = 1)]
const EComponentMissing: vector<u8> = b"PowerGrid component is not installed on this entity";
#[error(code = 2)]
const EAlreadyOn: vector<u8> = b"Power grid is already on";
#[error(code = 3)]
const EAlreadyOff: vector<u8> = b"Power grid is already off";
#[error(code = 4)]
const EModulesConnected: vector<u8> = b"Power grid still has connected modules";
#[error(code = 5)]
const EPowerSourcesPresent: vector<u8> = b"Power grid still has generators or fuel sources";

// === Constants ===

const VERSION: u64 = 1;
const NAME: vector<u8> = b"power_grid";

// === Structs ===

/// Pooled fuel and capacity for one Creation, plus who is connected and who is drawing.
public struct PowerGrid has store {
    on: bool,
    /// Fuel remaining as of `last_settled_ms`, not live.
    settled_fuel_quantity: u64,
    /// Sum of attached Fuel components rated capacity.
    fuel_capacity: u64,
    /// Blended (weighted-average) fuel quality, fixed point.
    fuel_impulse: u64,
    /// Blended (weighted-average) fuel containment burden. Each
    /// Generator's `containment_reduction` offsets it when computing how
    /// efficiently that Generator burns the pooled fuel.
    fuel_containment_burden: u64,
    /// Sum of online Generators' rated output, in MW.
    capacity_mw: u64,
    /// Sum of reservations' `active_draw`, in MW.
    used_mw: u64,
    /// Timestamp `settled_fuel_quantity` was last computed at.
    last_settled_ms: u64,
    // TODO: this can be a category later and priority can be a sibling of it.
    /// Connected modules: component id & priority (lower value = higher priority, by default all priority = 0).
    connected: VecMap<u64, u64>,
    /// Generators feeding the grid: component id => state, pushed by the
    /// Generator on install/online/offline so `settle` never reads siblings.
    generators: VecMap<u64, GeneratorState>,
    /// Component ids of Fuel components feeding the grid.
    fuel_sources: VecSet<u64>,
    /// Power reservations by module component id (priority lives in `connected`).
    reservations: VecMap<u64, Reservation>,
}

/// How a reservation is granted: Firm is all-or-nothing, Elastic takes leftover.
public enum DrawKind has copy, drop, store {
    Firm,
    Elastic,
}

/// The grid's copy of a Generator's state (not the `Generator` component
/// itself). The fuel factor for this Generator is computed from the blended
/// fuel and `containment_reduction`.
public struct GeneratorState has copy, drop, store {
    max_output_mw: u64,
    containment_reduction: u64,
    online: bool,
}

/// One module's power ask and its current grant.
public struct Reservation has drop, store {
    /// MW asked.
    requested: u64,
    line_loss: u64,
    /// MW granted right now; 0 = none. Firm is 0 or `requested`.
    active_draw: u64,
    kind: DrawKind,
}

/// Requirement marker satisfied by `power_on`.
public struct PowerOn() has drop;

/// Requirement marker satisfied by `power_off`.
public struct PowerOff() has drop;

// === Events ===

public struct PowerGridInstalled has copy, drop {
    entity_id: ID,
    component_id: u64,
}

public struct PowerGridUninstalled has copy, drop {
    entity_id: ID,
    component_id: u64,
}

public struct PowerToggled has copy, drop {
    entity_id: ID,
    on: bool,
}

// === Public Functions ===

/// Build and install the power grid at its well-known slot, switched off and
/// empty. Admin-gated by `entity::install`.
public fun install(entity: &mut Entity, clock: &Clock, ctx: &mut TxContext): Request {
    let entity_id = entity.id();
    let grid = PowerGrid {
        on: false,
        settled_fuel_quantity: 0,
        fuel_capacity: 0,
        fuel_impulse: 0,
        fuel_containment_burden: 0,
        capacity_mw: 0,
        used_mw: 0,
        last_settled_ms: clock.timestamp_ms(),
        connected: vec_map::empty(),
        generators: vec_map::empty(),
        fuel_sources: vec_set::empty(),
        reservations: vec_map::empty(),
    };
    let req = entity.install(
        component_id(),
        option::some(component_label()),
        grid,
        VERSION,
        power_grid_permit(),
        ctx,
    );
    event::emit(PowerGridInstalled { entity_id, component_id: component_id() });
    req
}

/// Remove the power grid. Aborts while any module is connected or any
/// Generator or Fuel component still feeds it.
public fun uninstall(entity: &mut Entity, ctx: &mut TxContext): Request {
    assert!(entity.has_component_with_type<PowerGrid>(component_id()), EComponentMissing);

    let (grid_component, req) = entity.uninstall<PowerGrid>(
        component_id(),
        power_grid_permit(),
        ctx,
    );
    assert!(component::version(&grid_component) == VERSION, EWrongVersion);
    let grid = grid_component.unwrap(power_grid_permit());
    assert!(grid.connected.is_empty(), EModulesConnected);
    assert!(grid.generators.is_empty() && grid.fuel_sources.is_empty(), EPowerSourcesPresent);
    let PowerGrid { .. } = grid;
    event::emit(PowerGridUninstalled { entity_id: entity.id(), component_id: component_id() });
    req
}

/// Switch the grid on. Next requirement must be this component's `PowerOn`.
public fun power_on(entity: &mut Entity, req: &mut Request, clock: &Clock) {
    let entity_id = entity.id();
    let (_requirement, frame, grid) = take(entity, req, power_on_permit());
    assert!(!grid.on, EAlreadyOn);
    grid.settle(clock);
    grid.on = true;
    event::emit(PowerToggled { entity_id, on: true });
    frame.destroy_empty_frame();
}

/// Switch the grid off. Next requirement must be this component's `PowerOff`.
public fun power_off(entity: &mut Entity, req: &mut Request, clock: &Clock) {
    let entity_id = entity.id();
    let (_requirement, frame, grid) = take(entity, req, power_off_permit());
    assert!(grid.on, EAlreadyOff);
    grid.settle(clock);
    grid.on = false;
    event::emit(PowerToggled { entity_id, on: false });
    frame.destroy_empty_frame();
}

/// Build a power-on requirement targeting the power grid slot.
public fun power_on_requirement(): Requirement {
    requirement::from_config(option::some(component_id()), PowerOn())
}

/// Build a power-off requirement targeting the power grid slot.
public fun power_off_requirement(): Requirement {
    requirement::from_config(option::some(component_id()), PowerOff())
}

// === View Functions ===

/// Borrow the installed power grid. Aborts if missing.
public fun power_grid(entity: &Entity): &PowerGrid {
    assert!(entity.has_component_with_type<PowerGrid>(component_id()), EComponentMissing);
    let c: &Component<PowerGrid> = entity.component_ref(component_id(), power_grid_permit());
    assert!(component::version(c) == VERSION, EWrongVersion);
    c.inner()
}

/// Capacity available to reservations: zero while off, else `capacity_mw`.
public fun effective_capacity_mw(grid: &PowerGrid): u64 {
    if (grid.on) grid.capacity_mw else 0
}

public fun component_id(): u64 {
    component::id_from_name(NAME)
}

public fun on(grid: &PowerGrid): bool {
    grid.on
}

public fun settled_fuel_quantity(grid: &PowerGrid): u64 {
    grid.settled_fuel_quantity
}

public fun fuel_capacity(grid: &PowerGrid): u64 {
    grid.fuel_capacity
}

public fun fuel_impulse(grid: &PowerGrid): u64 {
    grid.fuel_impulse
}

public fun capacity_mw(grid: &PowerGrid): u64 {
    grid.capacity_mw
}

public fun used_mw(grid: &PowerGrid): u64 {
    grid.used_mw
}

public fun fuel_containment_burden(grid: &PowerGrid): u64 {
    grid.fuel_containment_burden
}

public fun last_settled_ms(grid: &PowerGrid): u64 {
    grid.last_settled_ms
}

public fun connected(grid: &PowerGrid): &VecMap<u64, u64> {
    &grid.connected
}

public fun generators(grid: &PowerGrid): &VecMap<u64, GeneratorState> {
    &grid.generators
}

public fun fuel_sources(grid: &PowerGrid): &VecSet<u64> {
    &grid.fuel_sources
}

public fun reservations(grid: &PowerGrid): &VecMap<u64, Reservation> {
    &grid.reservations
}

public fun max_output_mw(state: &GeneratorState): u64 {
    state.max_output_mw
}

public fun containment_reduction(state: &GeneratorState): u64 {
    state.containment_reduction
}

public fun online(state: &GeneratorState): bool {
    state.online
}

public fun requested(reservation: &Reservation): u64 {
    reservation.requested
}

public fun line_loss(reservation: &Reservation): u64 {
    reservation.line_loss
}

public fun active_draw(reservation: &Reservation): u64 {
    reservation.active_draw
}

public fun kind(reservation: &Reservation): DrawKind {
    reservation.kind
}

public fun is_firm(kind: &DrawKind): bool {
    match (kind) {
        DrawKind::Firm => true,
        DrawKind::Elastic => false,
    }
}

// === Private Functions ===

/// Borrow the grid mid-interaction, popping the next requirement of type `T`.
fun take<T: drop>(
    entity: &mut Entity,
    req: &mut Request,
    permit: Permit<T>,
): (Requirement, Frame, &mut PowerGrid) {
    let c: &mut Component<PowerGrid> = entity.component_mut(req, power_grid_permit());
    assert!(component::version(c) == VERSION, EWrongVersion);
    let grid = c.inner_mut();
    let (requirement, frame) = req.take_next(permit);
    (requirement, frame, grid)
}

/// Advance fuel state to now.
fun settle(grid: &mut PowerGrid, clock: &Clock) {
    grid.last_settled_ms = clock.timestamp_ms();
}

fun component_label(): String {
    string::utf8(NAME)
}

fun power_grid_permit(): Permit<PowerGrid> {
    internal::permit<PowerGrid>()
}

fun power_on_permit(): Permit<PowerOn> {
    internal::permit<PowerOn>()
}

fun power_off_permit(): Permit<PowerOff> {
    internal::permit<PowerOff>()
}

// === Test Functions ===

/// Standalone grid for unit-testing pure views.
#[test_only]
public fun new_for_testing(on: bool, capacity_mw: u64): PowerGrid {
    PowerGrid {
        on,
        settled_fuel_quantity: 0,
        fuel_capacity: 0,
        fuel_impulse: 0,
        fuel_containment_burden: 0,
        capacity_mw,
        used_mw: 0,
        last_settled_ms: 0,
        connected: vec_map::empty(),
        generators: vec_map::empty(),
        fuel_sources: vec_set::empty(),
        reservations: vec_map::empty(),
    }
}

#[test_only]
public fun destroy_for_testing(grid: PowerGrid) {
    let PowerGrid { .. } = grid;
}

/// `(entity_id, component_id)`.
#[test_only]
public fun installed_fields(e: &PowerGridInstalled): (ID, u64) {
    (e.entity_id, e.component_id)
}

/// `(entity_id, on)`.
#[test_only]
public fun toggled_fields(e: &PowerToggled): (ID, bool) {
    (e.entity_id, e.on)
}
