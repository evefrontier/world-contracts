/// Power grid component installed on an `Entity`: one per Creation, at a
/// well-known component slot. Pools the capacity of its Generators and the fuel
/// of its Fuel components, and grants Firm or Elastic draws to connected modules.
///
/// Power On/Off is the Creation-level master switch. Off treats capacity as
/// zero. The owner or admin bundles `set_power_grid_requirement` into an
/// action; the caller passes on or off when the action runs.
///
/// Any action can also require a minimum grid state with
/// `power_grid_requirement`, checked by `assert_power_grid`, or a generator
/// state with `generator_requirement`, checked by `assert_generator`.
///
/// See `docs/adr/0005-onchain-power-network.md`.
module power::power_grid;

use core::{
    admin_service,
    component::{Self, Component},
    entity::Entity,
    request::{Request, Frame},
    requirement::{Self, Requirement}
};
use power::generator;
use std::{internal::Permit, string::{Self, String}};
use sui::{bcs, clock::Clock, event, vec_map::{Self, VecMap}, vec_set::{Self, VecSet}};

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
#[error(code = 6)]
const EGeneratorAlreadyRegistered: vector<u8> =
    b"Generator is already registered with this power grid";
#[error(code = 7)]
const EGeneratorNotRegistered: vector<u8> = b"Generator is not registered with this power grid";
#[error(code = 8)]
const EGeneratorOnline: vector<u8> = b"Generator must be offline to be removed from the grid";
#[error(code = 9)]
const EGeneratorAlreadyOnline: vector<u8> = b"Generator is already online";
#[error(code = 10)]
const EGeneratorAlreadyOffline: vector<u8> = b"Generator is already offline";
#[error(code = 11)]
const EGeneratorStillRegistered: vector<u8> =
    b"Generator must be unregistered from the power grid before uninstall";
#[error(code = 12)]
const EGridState: vector<u8> = b"Power grid on/off state does not match the requirement";
#[error(code = 13)]
const EFuelBelowMin: vector<u8> = b"Fuel quantity is below the requirement";
#[error(code = 14)]
const EImpulseBelowMin: vector<u8> = b"Fuel impulse is below the requirement";
#[error(code = 15)]
const ECapacityBelowMin: vector<u8> = b"Rated capacity is below the requirement";
#[error(code = 16)]
const EUsedBelowMin: vector<u8> = b"Used power is below the requirement";
#[error(code = 17)]
const EGeneratorState: vector<u8> = b"Generator online state does not match the requirement";
#[error(code = 18)]
const EOutputBelowMin: vector<u8> = b"Generator output is below the requirement";
#[error(code = 19)]
const EContainmentBelowMin: vector<u8> = b"Containment reduction is below the requirement";

// === Constants ===

const VERSION: u64 = 1;
const NAME: vector<u8> = b"power_grid";

// === Structs ===

/// Pooled fuel and capacity for one Creation, plus who is connected and who is drawing.
public struct PowerGrid has store {
    on: bool,
    /// Fuel remaining as of `last_settled_ms`, not live.
    settled_fuel_quantity: u64,
    /// Sum of Fuel components' rated capacity.
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
    /// Generators feeding the grid by component id.
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

/// A Generator's stats and online state, held only by the grid. Stats are
/// fixed from install to uninstall. The fuel factor for this Generator is
/// computed from the blended fuel and `containment_reduction`.
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

/// Requirement marker satisfied by `set_power_grid`.
public struct SetPowerGrid() has drop;

/// Minimum grid state any action can require. `assert_power_grid` checks it
/// against stored state. Each number is a minimum (`>=`). `None` skips that
/// check. `capacity_mw` is always checked; pass 0 to allow any rated output.
public struct PowerGridRequirement has drop {
    on: bool,
    /// Minimum `settled_fuel_quantity`, if set.
    fuel_quantity: Option<u64>,
    /// Minimum `fuel_impulse`, if set.
    fuel_impulse: Option<u64>,
    /// Minimum rated `capacity_mw`.
    capacity_mw: u64,
    /// Minimum `used_mw`, if set.
    used_mw: Option<u64>,
}

/// Requirement marker satisfied by `register_generator` or
/// `unregister_generator`. Both push an admin requirement, so one admin-only
/// marker covers both.
public struct ManageGenerator() has drop;

/// Requirement marker satisfied by `set_generator`. Which generator and whether
/// it comes online are call arguments.
public struct SetGenerator() has drop;

/// Minimum state of one registered Generator. `assert_generator` checks it.
/// Each number is a minimum (`>=`). `None` skips that check.
public struct GeneratorRequirement has drop {
    generator_id: u64,
    online: bool,
    /// Minimum `max_output_mw`, if set.
    max_output_mw: Option<u64>,
    /// Minimum `containment_reduction`, if set.
    containment_reduction: Option<u64>,
}

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

/// Emitted when online Generator output changes the grid's `capacity_mw`.
public struct CapacityChanged has copy, drop {
    entity_id: ID,
    capacity_mw: u64,
}

public struct GeneratorRegistered has copy, drop {
    entity_id: ID,
    generator_id: u64,
    max_output_mw: u64,
    containment_reduction: u64,
}

public struct GeneratorUnregistered has copy, drop {
    entity_id: ID,
    generator_id: u64,
}

public struct GeneratorToggled has copy, drop {
    entity_id: ID,
    generator_id: u64,
    online: bool,
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

// TODO: this is only for admin ops while to clear the orphaned data during entity uninstall
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

// TODO: This power grid level shut down and on
/// Switch the grid on or off.
public fun set_power_grid(entity: &mut Entity, req: &mut Request, on: bool, clock: &Clock) {
    let entity_id = entity.id();
    let (_requirement, frame, grid) = take(entity, req, set_power_grid_permit());
    if (on) assert!(!grid.on, EAlreadyOn) else assert!(grid.on, EAlreadyOff);
    grid.settle(clock);
    grid.on = on;
    event::emit(PowerToggled { entity_id, on });
    frame.destroy_empty_frame();
}

/// Build the requirement satisfied by `set_power_grid`. On or off is not
/// stored here; the caller passes it.
public fun set_power_grid_requirement(): Requirement {
    requirement::from_config(option::some(component_id()), SetPowerGrid())
}

/// Abort unless the installed grid meets the next `PowerGridRequirement`.
/// Reads stored state and does not settle fuel.
public fun assert_power_grid(entity: &mut Entity, req: &mut Request) {
    let (requirement, frame, grid) = take(entity, req, power_grid_requirement_permit());
    enforce_power_grid(&requirement, grid);
    frame.destroy_empty_frame();
}

/// Build a `PowerGridRequirement` on this grid. See that struct for the checks.
public fun power_grid_requirement(
    on: bool,
    fuel_quantity: Option<u64>,
    fuel_impulse: Option<u64>,
    capacity_mw: u64,
    used_mw: Option<u64>,
): Requirement {
    requirement::from_config(
        option::some(component_id()),
        PowerGridRequirement { on, fuel_quantity, fuel_impulse, capacity_mw, used_mw },
    )
}

/// Register the installed Generator `generator_id` with the grid, offline, with
/// its fixed stats. Next requirement must be `ManageGenerator`. Pushes an admin
/// requirement.
public fun register_generator(
    entity: &mut Entity,
    req: &mut Request,
    generator_id: u64,
    max_output_mw: u64,
    containment_reduction: u64,
    clock: &Clock,
) {
    generator::assert_installed(entity, generator_id);
    let entity_id = entity.id();
    let (_requirement, mut frame, grid) = take(entity, req, manage_generator_permit());
    assert!(!grid.generators.contains(&generator_id), EGeneratorAlreadyRegistered);
    grid.settle(clock);
    grid
        .generators
        .insert(
            generator_id,
            GeneratorState { max_output_mw, containment_reduction, online: false },
        );
    event::emit(GeneratorRegistered {
        entity_id,
        generator_id,
        max_output_mw,
        containment_reduction,
    });
    frame.require(admin_service::admin_requirement());
    req.enqueue(frame);
}

/// Remove offline Generator `generator_id` from the grid. Next requirement must
/// be `ManageGenerator`. Pushes an admin requirement.
public fun unregister_generator(
    entity: &mut Entity,
    req: &mut Request,
    generator_id: u64,
    clock: &Clock,
) {
    let entity_id = entity.id();
    let (_requirement, mut frame, grid) = take(entity, req, manage_generator_permit());
    assert!(grid.generators.contains(&generator_id), EGeneratorNotRegistered);
    // TODO: we can automatically offline and unregister if needed
    assert!(!grid.generators.get(&generator_id).online, EGeneratorOnline);
    grid.settle(clock);
    grid.generators.remove(&generator_id);
    event::emit(GeneratorUnregistered { entity_id, generator_id });
    frame.require(admin_service::admin_requirement());
    req.enqueue(frame);
}

/// Uninstall Generator `generator_id`. Aborts while it is registered with the
/// grid. Admin-gated by `entity::uninstall`.
public fun uninstall_generator(
    entity: &mut Entity,
    generator_id: u64,
    ctx: &mut TxContext,
): Request {
    // TODO: we can automatically offline and unregister if needed
    assert!(!is_generator_registered(entity, generator_id), EGeneratorStillRegistered);
    generator::uninstall(entity, generator_id, ctx)
}

/// Bring Generator `generator_id` online or offline. `online` is chosen by the
/// caller. The next requirement must be `SetGenerator`
/// (`set_generator_requirement`).
public fun set_generator(
    entity: &mut Entity,
    req: &mut Request,
    generator_id: u64,
    online: bool,
    clock: &Clock,
) {
    let entity_id = entity.id();
    let (_requirement, frame, grid) = take(entity, req, set_generator_permit());
    grid.set_generator_online(entity_id, generator_id, online, clock);
    frame.destroy_empty_frame();
}

/// Build the requirement satisfied by `set_generator`.
public fun set_generator_requirement(): Requirement {
    requirement::from_config(option::some(component_id()), SetGenerator())
}

/// Abort unless Generator `generator_id` on the grid meets the next
/// `GeneratorRequirement`. Reads stored state.
public fun assert_generator(entity: &mut Entity, req: &mut Request) {
    let (requirement, frame, grid) = take(entity, req, generator_requirement_permit());
    enforce_generator(&requirement, grid);
    frame.destroy_empty_frame();
}

/// Build a `GeneratorRequirement` on this grid. See that struct for the checks.
public fun generator_requirement(
    generator_id: u64,
    online: bool,
    max_output_mw: Option<u64>,
    containment_reduction: Option<u64>,
): Requirement {
    requirement::from_config(
        option::some(component_id()),
        GeneratorRequirement { generator_id, online, max_output_mw, containment_reduction },
    )
}

// === View Functions ===

/// Borrow the installed power grid. Aborts if missing.
public fun power_grid(entity: &Entity): &PowerGrid {
    assert!(entity.has_component_with_type<PowerGrid>(component_id()), EComponentMissing);
    let c: &Component<PowerGrid> = entity.component_ref(component_id(), power_grid_permit());
    assert!(component::version(c) == VERSION, EWrongVersion);
    c.inner()
}

/// The grid's state for Generator `generator_id`. Aborts if the Generator is
/// not installed, the grid is missing, or the Generator is not registered.
public fun generator_state(entity: &Entity, generator_id: u64): GeneratorState {
    generator::assert_installed(entity, generator_id);
    *power_grid(entity).generators.get(&generator_id)
}

/// True if Generator `generator_id` is registered with an installed grid.
public fun is_generator_registered(entity: &Entity, generator_id: u64): bool {
    entity.has_component_with_type<PowerGrid>(component_id())
        && power_grid(entity).generators.contains(&generator_id)
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

public fun required_on(rule: &PowerGridRequirement): bool {
    rule.on
}

public fun required_fuel_quantity(rule: &PowerGridRequirement): Option<u64> {
    rule.fuel_quantity
}

public fun required_fuel_impulse(rule: &PowerGridRequirement): Option<u64> {
    rule.fuel_impulse
}

public fun required_capacity_mw(rule: &PowerGridRequirement): u64 {
    rule.capacity_mw
}

public fun required_used_mw(rule: &PowerGridRequirement): Option<u64> {
    rule.used_mw
}

public fun required_generator_id(rule: &GeneratorRequirement): u64 {
    rule.generator_id
}

public fun required_generator_online(rule: &GeneratorRequirement): bool {
    rule.online
}

public fun required_max_output_mw(rule: &GeneratorRequirement): Option<u64> {
    rule.max_output_mw
}

public fun required_containment_reduction(rule: &GeneratorRequirement): Option<u64> {
    rule.containment_reduction
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

/// Flip a registered Generator online or offline and adjust `capacity_mw` by
/// its rated output.
fun set_generator_online(
    grid: &mut PowerGrid,
    entity_id: ID,
    generator_id: u64,
    online: bool,
    clock: &Clock,
) {
    assert!(grid.generators.contains(&generator_id), EGeneratorNotRegistered);
    // Settle before capacity changes: fuel burn depends on which Generators run.
    grid.settle(clock);
    let state = grid.generators.get_mut(&generator_id);
    if (online) assert!(!state.online, EGeneratorAlreadyOnline)
    else assert!(state.online, EGeneratorAlreadyOffline);
    state.online = online;
    let output = state.max_output_mw;
    grid.capacity_mw = if (online) grid.capacity_mw + output else grid.capacity_mw - output;
    // TODO(slice 4): rebalance reservations against the new capacity.
    event::emit(GeneratorToggled { entity_id, generator_id, online });
    event::emit(CapacityChanged { entity_id, capacity_mw: grid.capacity_mw });
}

/// Decode a `PowerGridRequirement` and abort if the grid is short of it.
/// Field order matches the struct.
fun enforce_power_grid(requirement: &Requirement, grid: &PowerGrid) {
    let mut encoded = bcs::new(requirement.data());
    let on = encoded.peel_bool();
    let fuel_quantity = encoded.peel_option_u64();
    let fuel_impulse = encoded.peel_option_u64();
    let capacity_mw = encoded.peel_u64();
    let used_mw = encoded.peel_option_u64();
    assert!(grid.on == on, EGridState);
    fuel_quantity.do!(|min_fuel| assert!(grid.settled_fuel_quantity >= min_fuel, EFuelBelowMin));
    fuel_impulse.do!(|min_impulse| assert!(grid.fuel_impulse >= min_impulse, EImpulseBelowMin));
    assert!(grid.capacity_mw >= capacity_mw, ECapacityBelowMin);
    used_mw.do!(|min_used| assert!(grid.used_mw >= min_used, EUsedBelowMin));
}

/// Decode a `GeneratorRequirement` and abort if that Generator is short of it.
/// Field order matches the struct.
fun enforce_generator(requirement: &Requirement, grid: &PowerGrid) {
    let mut encoded = bcs::new(requirement.data());
    let generator_id = encoded.peel_u64();
    let online = encoded.peel_bool();
    let max_output_mw = encoded.peel_option_u64();
    let containment_reduction = encoded.peel_option_u64();
    assert!(grid.generators.contains(&generator_id), EGeneratorNotRegistered);
    let state = grid.generators.get(&generator_id);
    assert!(state.online == online, EGeneratorState);
    max_output_mw.do!(|min_output| assert!(state.max_output_mw >= min_output, EOutputBelowMin));
    containment_reduction.do!(|min_containment| {
        assert!(state.containment_reduction >= min_containment, EContainmentBelowMin)
    });
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

fun set_power_grid_permit(): Permit<SetPowerGrid> {
    internal::permit<SetPowerGrid>()
}

fun power_grid_requirement_permit(): Permit<PowerGridRequirement> {
    internal::permit<PowerGridRequirement>()
}

fun manage_generator_permit(): Permit<ManageGenerator> {
    internal::permit<ManageGenerator>()
}

fun set_generator_permit(): Permit<SetGenerator> {
    internal::permit<SetGenerator>()
}

fun generator_requirement_permit(): Permit<GeneratorRequirement> {
    internal::permit<GeneratorRequirement>()
}

// === Test Functions ===

#[test_only]
public fun manage_generator_requirement(): Requirement {
    requirement::from_config(option::some(component_id()), ManageGenerator())
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
