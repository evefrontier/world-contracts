/// Power grid component: one per Creation, at a well-known slot. Owns the fuel
/// bays and their fuel, capacity, the connected modules and their grants.
/// Modules, generators and fuel bays connect when installed and disconnect when
/// uninstalled. Online bays burn together, each in proportion to what it holds.
/// Grants are derived from each module's desired state and the live capacity at
/// every settle. Fuel bays live in `grid_fuel`, generator state in
/// `grid_generator`, and connect, disconnect and desired state in `grid_load`.
/// Burn math lives in `fuel_math`. Every mutating path settles before it changes
/// state. Power, bay capacity, fuel stats and every input are plain integers.
/// Stored fuel quantity is fixed point at `fuel_math::scale` so burn stays exact.
/// See `docs/adr/0005-onchain-power-network.md`.
module power::power_grid;

use core::{
    access_cap,
    admin_service,
    component::{Self, Component},
    entity::Entity,
    request::{Request, Frame},
    requirement::{Self, Requirement}
};
use power::{fuel_math, generator};
use std::{internal::Permit, string::{Self, String}};
use sui::{bcs, clock::Clock, event, vec_map::{Self, VecMap}};

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
const EModulesConnected: vector<u8> = b"Power grid still has modules connected";
#[error(code = 5)]
const EPowerSourcesPresent: vector<u8> = b"Power grid still has generators or fuel bays";
#[error(code = 6)]
const EGridState: vector<u8> = b"Power grid on/off state does not match the requirement";
#[error(code = 7)]
const EFuelBelowMin: vector<u8> = b"Fuel quantity is below the requirement";
#[error(code = 8)]
const EImpulseBelowMin: vector<u8> = b"Fuel impulse is below the requirement";
#[error(code = 9)]
const ECapacityBelowMin: vector<u8> = b"Rated capacity is below the requirement";
#[error(code = 10)]
const EUsedAboveMax: vector<u8> = b"Used power is above the requirement";
#[error(code = 11)]
const EModuleNotConnected: vector<u8> = b"Module is not connected to this power grid";
#[error(code = 12)]
const EFuelBayNotConnected: vector<u8> = b"Fuel bay is not connected to this power grid";
#[error(code = 13)]
const EUnknownDrawKind: vector<u8> = b"Unknown draw kind";
#[error(code = 14)]
const EFuelStashed: vector<u8> = b"Power grid still holds stashed fuel of uninstalled bays";
#[error(code = 15)]
const EWouldOverload: vector<u8> =
    b"Desired Firm power would exceed the online generators' output and turn every module off";

// === Constants ===

const VERSION: u64 = 1;
const NAME: vector<u8> = b"power_grid";
/// Cap on connected modules.
const MAX_CONNECTED: u64 = 100;

// === Structs ===

/// Fuel bays, capacity, connected modules and installed generators.
public struct PowerGrid has store {
    on: bool,
    /// Timestamp the bays' fuel was last settled at.
    last_settled_ms: u64,
    /// Connected modules by component id.
    modules: VecMap<u64, ModuleState>,
    /// Installed Generators by component id.
    generators: VecMap<u64, GeneratorState>,
    /// Installed fuel bays by component id. One per fitted bay, so tens at most.
    bays: VecMap<u64, FuelBayState>,
    /// Exact fuel of uninstalled bays by component id, until the bay is refitted
    /// here or the service takes it out with `grid_fuel::take_stash`. Stashed
    /// fuel never burns. One entry per bay removed and not yet refitted.
    stashed: VecMap<u64, Fuel>,
}

/// A fuel bay's capacity, online state and fuel, held by the grid.
public struct FuelBayState has copy, drop, store {
    /// Plain fuel units.
    capacity: u64,
    /// Only online bays feed the grid. An offline bay keeps its fuel.
    online: bool,
    /// As of `last_settled_ms`, not live. See `projected_bays` for now.
    fuel: Fuel,
}

/// A quantity of fuel at `SCALE` and its plain stats. Loading fuel blends the
/// stats by quantity-weighted average. Inside a stored `FuelBayState` the
/// quantity is as of `last_settled_ms`, not live; `projected_bays` gives it now.
public struct Fuel has copy, drop, store {
    quantity: u64,
    impulse: u64,
    containment_burden: u64,
    volatility: u64,
}

/// A Generator's fixed stats and online state, held by the grid.
public struct GeneratorState has copy, drop, store {
    /// Plain MW.
    max_output_mw: u64,
    /// Softens the fuel's containment burden for this Generator's burn.
    containment_reduction: u64,
    /// Units per second burned while online and the fuel has zero impulse.
    base_fuel_rate: u64,
    online: bool,
}

/// A connected module: the spec it declared, plus desired state and last-settled grant.
public struct ModuleState has copy, drop, store {
    module_spec: ModulePowerSpec,
    /// Owner intent. Set with `set_desired_state`.
    desired_online: bool,
    /// Power modules: MW granted at the last settle, plain; zero means no grant.
    /// Fuel modules: fuel per second at `SCALE` while desired online, set by
    /// the service.
    active_draw_at_last_settled: u64,
}

/// The power spec a module declares at install. Stored inside `ModuleState`.
public struct ModulePowerSpec has copy, drop, store {
    /// MW the module needs to operate, plain.
    power_req: u64,
    draw_kind: DrawKind,
    power_kind: PowerKind,
    /// Priority group. Stored only; grants ignore it in v1.
    priority: u64,
    /// Stored only; grants and fuel burn ignore it in v1.
    line_loss: u64,
}

/// How a module draws: Firm needs its full `power_req` or nothing, Elastic
/// takes what is left.
public enum DrawKind has copy, drop, store {
    Firm,
    Elastic,
}

/// What a module draws from. `Power` modules take grants from the generators.
/// `Fuel` modules (leap, overdrive) burn a rate straight from the online bays
/// while online and the grid is on; they have `power_req = 0` and take no part
/// in grants or overload.
public enum PowerKind has copy, drop, store {
    Power,
    Fuel,
}

/// Marker for the owner's grid operations: `set_power_grid`, `set_generator`,
/// `set_priority` and `set_desired_state`. Each also requires the owner in its
/// own frame.
public struct OperateGrid() has drop;

/// Marker for the service taking a stash out with `grid_fuel::take_stash` or
/// putting fuel back with `grid_fuel::stash_load`. The frame then requires the admin.
public struct ManageStash() has drop;

/// Marker for the service switching a fuel module with
/// `grid_load::set_fuel_module`. The frame then requires the admin.
public struct OperateFuelModule() has drop;

/// Marker for the service taking warp fuel with `grid_fuel::withdraw_fuel`.
/// The frame then requires the admin.
public struct WithdrawFuel() has drop;

/// Marker for the service shutting a Creation down with `shut_down`. The frame
/// then requires the admin.
public struct ShutDown() has drop;

/// The owner's overload pre-filter. Put after a grid operation in an action
/// (`set_desired_state`, `set_generator`, ...), it aborts the whole transaction
/// if the desired Firm load no longer fits, so nothing turns off.
public struct Fits() has drop;

/// Minimum grid state an action can require. `None` skips a check.
public struct PowerGridRequirement has drop {
    on: bool,
    /// Minimum fuel in online bays, plain units, if set.
    fuel_quantity: Option<u64>,
    /// Minimum blended impulse of the online bays, if set.
    fuel_impulse: Option<u64>,
    /// Minimum rated `capacity_mw`.
    capacity_mw: u64,
    /// Maximum `used_mw`, if set.
    used_mw: Option<u64>,
}

// TODO: this is not very essential
/// Minimum state of one Generator. `None` skips a check.
public struct GeneratorRequirement has drop {
    generator_id: u64,
    online: bool,
    /// Minimum `max_output_mw`, if set.
    max_output_mw: Option<u64>,
    /// Minimum `containment_reduction`, if set.
    containment_reduction: Option<u64>,
}

/// The owner's rules for which fuel `deposit_fuel` accepts. Empty `fuel_types`
/// or `None` skips a check. Stats and amounts plain.
public struct FuelRequirement has drop {
    /// Allowed fuel type ids; empty allows any.
    fuel_types: vector<u64>,
    min_impulse: Option<u64>,
    max_containment_burden: Option<u64>,
    min_amount: Option<u64>,
    max_amount: Option<u64>,
}

/// Requirement satisfied by `deposit_fuel`, carrying the owner's `FuelRequirement`.
public struct DepositFuel(FuelRequirement) has drop;

/// `module_id` holds a grant of `draw_kind` with at least `draw` MW.
public struct OnlineRequirement has drop {
    module_id: u64,
    draw: u64,
    draw_kind: DrawKind,
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

/// The service shut the Creation down: every module's intent cleared and every
/// generator and bay offline.
public struct GridShutDown has copy, drop {
    entity_id: ID,
}

public struct PowerToggled has copy, drop {
    entity_id: ID,
    on: bool,
}

/// A module's granted draw changed at a settle.
public struct DrawChanged has copy, drop {
    entity_id: ID,
    module_id: u64,
    active_draw: u64,
}

// === Public Functions ===

/// Install the grid, off and empty. Admin-gated.
public fun install(entity: &mut Entity, clock: &Clock, ctx: &mut TxContext): Request {
    let entity_id = entity.id();
    let grid = PowerGrid {
        on: false,
        last_settled_ms: clock.timestamp_ms(),
        modules: vec_map::empty(),
        generators: vec_map::empty(),
        bays: vec_map::empty(),
        stashed: vec_map::empty(),
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
/// Remove the grid. Aborts while any module, generator or fuel bay is installed.
public fun uninstall(entity: &mut Entity, ctx: &mut TxContext): Request {
    assert!(entity.has_component_with_type<PowerGrid>(component_id()), EComponentMissing);

    let (grid_component, req) = entity.uninstall<PowerGrid>(
        component_id(),
        power_grid_permit(),
        ctx,
    );
    assert!(component::version(&grid_component) == VERSION, EWrongVersion);
    let grid = grid_component.unwrap(power_grid_permit());
    assert!(grid.modules.is_empty(), EModulesConnected);
    assert!(grid.generators.is_empty() && grid.bays.is_empty(), EPowerSourcesPresent);
    assert!(grid.stashed.is_empty(), EFuelStashed);
    let PowerGrid { .. } = grid;
    event::emit(PowerGridUninstalled { entity_id: entity.id(), component_id: component_id() });
    req
}

/// Switch the grid on or off. Settles at the old state, then regrants.
public fun set_power_grid(entity: &mut Entity, req: &mut Request, on: bool, clock: &Clock) {
    let entity_id = entity.id();
    let (_requirement, mut frame, grid) = take_grid(entity, req, operate_grid_permit());
    if (on) assert!(!grid.on, EAlreadyOn) else assert!(grid.on, EAlreadyOff);
    grid.settle(clock);
    grid.on = on;
    event::emit(PowerToggled { entity_id, on });
    grid.regrant(entity_id);
    frame.require(access_cap::owner_requirement());
    req.enqueue(frame);
}

/// Shut the Creation down when it loses its Shell: clear every module's desired
/// state, stop every fuel module, and take every generator and bay offline.
/// Unlike Power Off, nothing comes back by itself; the owner switches things on
/// again. `on` is unchanged. The service calls it in the same transaction as the
/// Layout edit that removes the Shell. The request needs a
/// `shut_down_requirement`, and the frame then requires the admin.
public fun shut_down(entity: &mut Entity, req: &mut Request, clock: &Clock) {
    let entity_id = entity.id();
    let (_requirement, mut frame, grid) = take_grid(entity, req, shut_down_permit());
    grid.settle(clock);
    grid.modules.length().do!(|i| {
        let (_, state) = grid.modules.get_entry_by_idx_mut(i);
        state.desired_online = false;
        if (state.module_spec.power_kind == PowerKind::Fuel) state.active_draw_at_last_settled = 0;
    });
    grid.generators.length().do!(|i| {
        let (_, generator) = grid.generators.get_entry_by_idx_mut(i);
        generator.online = false;
    });
    grid.bays.length().do!(|i| {
        let (_, bay) = grid.bays.get_entry_by_idx_mut(i);
        bay.online = false;
    });
    grid.regrant(entity_id);
    event::emit(GridShutDown { entity_id });
    frame.require(admin_service::admin_requirement());
    req.enqueue(frame);
}

/// Abort with `EWouldOverload` unless the desired Firm load fits the online
/// generators' output, as the action's earlier operations left it. Resolves a
/// `fits_requirement`. It can't catch fuel running out, which happens over time.
public fun assert_fits(entity: &mut Entity, req: &mut Request) {
    let (_requirement, frame, grid) = take_grid(entity, req, fits_permit());
    assert!(grid.desired_firm_mw() <= grid.capacity_mw(), EWouldOverload);
    frame.destroy_empty_frame();
}

/// The overload pre-filter. Add it after the grid operation in an owner
/// action; see `assert_fits`.
public fun fits_requirement(): Requirement {
    requirement::from_config(option::some(component_id()), Fits())
}

/// Requirement satisfied by `shut_down`; one per call.
public fun shut_down_requirement(): Requirement {
    requirement::from_config(option::some(component_id()), ShutDown())
}

/// Requirement satisfied by `grid_fuel::withdraw_fuel`; one per call.
public fun withdraw_fuel_requirement(): Requirement {
    requirement::from_config(option::some(component_id()), WithdrawFuel())
}

/// Requirement satisfied by `grid_load::set_fuel_module`; one per call.
public fun operate_fuel_module_requirement(): Requirement {
    requirement::from_config(option::some(component_id()), OperateFuelModule())
}

public fun manage_stash_requirement(): Requirement {
    requirement::from_config(option::some(component_id()), ManageStash())
}

/// Requirement satisfied by the owner's grid operations; one per call.
public fun operate_grid_requirement(): Requirement {
    requirement::from_config(option::some(component_id()), OperateGrid())
}

/// Abort unless the grid meets the next `PowerGridRequirement`.
/// Settles first, so burned fuel counts before the check.
public fun assert_power_grid(entity: &mut Entity, req: &mut Request, clock: &Clock) {
    let entity_id = entity.id();
    let (requirement, frame, grid) = take_grid(entity, req, power_grid_requirement_permit());
    grid.settle(clock);
    grid.regrant(entity_id);
    enforce_power_grid(&requirement, grid);
    frame.destroy_empty_frame();
}

/// Build a `PowerGridRequirement`.
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

/// Build a `GeneratorRequirement`.
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

/// Build an `OnlineRequirement` for `module_id`.
public fun online_requirement(module_id: u64, draw: u64, draw_kind: DrawKind): Requirement {
    requirement::from_config(
        option::some(component_id()),
        OnlineRequirement { module_id, draw, draw_kind },
    )
}

/// Build a `DepositFuel` requirement with the owner's fuel rules.
public fun deposit_fuel_requirement(
    fuel_types: vector<u64>,
    min_impulse: Option<u64>,
    max_containment_burden: Option<u64>,
    min_amount: Option<u64>,
    max_amount: Option<u64>,
): Requirement {
    requirement::from_config(
        option::some(component_id()),
        DepositFuel(FuelRequirement {
            fuel_types,
            min_impulse,
            max_containment_burden,
            min_amount,
            max_amount,
        }),
    )
}

/// A module's power spec, as passed to `grid_load::connect` at install.
public fun module_power_spec(
    power_req: u64,
    draw_kind: DrawKind,
    power_kind: PowerKind,
    priority: u64,
    line_loss: u64,
): ModulePowerSpec {
    ModulePowerSpec { power_req, draw_kind, power_kind, priority, line_loss }
}

/// Firm: all or nothing.
public fun firm(): DrawKind { DrawKind::Firm }

/// Elastic: up to the ask, from what is left.
public fun elastic(): DrawKind { DrawKind::Elastic }

/// Draws from power.
public fun power(): PowerKind { PowerKind::Power }

/// Draws fuel from the online bays at a rate.
public fun fuel_kind(): PowerKind { PowerKind::Fuel }

// === View Functions ===

/// Borrow the installed grid. Aborts if missing.
public fun power_grid(entity: &Entity): &PowerGrid {
    assert!(entity.has_component_with_type<PowerGrid>(component_id()), EComponentMissing);
    let grid_component: &Component<PowerGrid> = entity.component_ref(
        component_id(),
        power_grid_permit(),
    );
    assert!(component::version(grid_component) == VERSION, EWrongVersion);
    grid_component.inner()
}

/// An installed Generator's state.
public fun generator_state(entity: &Entity, generator_id: u64): GeneratorState {
    assert!(is_generator_connected(entity, generator_id), EComponentMissing);
    *power_grid(entity).generators.get(&generator_id)
}

/// True if the Generator is installed with an installed grid.
public fun is_generator_connected(entity: &Entity, generator_id: u64): bool {
    entity.has_component_with_type<PowerGrid>(component_id())
        && power_grid(entity).generators.contains(&generator_id)
}

/// True if the fuel bay is installed with an installed grid.
public fun is_fuel_bay_connected(entity: &Entity, fuel_bay_id: u64): bool {
    entity.has_component_with_type<PowerGrid>(component_id())
        && power_grid(entity).bays.contains(&fuel_bay_id)
}

/// An installed fuel bay's state as of the last settle, not live. See
/// `projected_bays` for its fuel now.
public fun fuel_bay_state(entity: &Entity, fuel_bay_id: u64): FuelBayState {
    assert!(is_fuel_bay_connected(entity, fuel_bay_id), EFuelBayNotConnected);
    power_grid(entity).bays[&fuel_bay_id]
}

/// Stashed fuel of uninstalled bay `fuel_bay_id`, if this grid holds any. A
/// stash never burns, so this is its quantity now.
public fun stashed_fuel(entity: &Entity, fuel_bay_id: u64): Option<Fuel> {
    let stashed = &power_grid(entity).stashed;
    if (stashed.contains(&fuel_bay_id)) option::some(stashed[&fuel_bay_id]) else option::none()
}

/// Capacity available to grants, as of the last settle: 0 while off or while
/// the online bays are empty.
public fun effective_capacity_mw(grid: &PowerGrid): u64 {
    if (grid.on && grid.online_fuel().quantity > 0) grid.capacity_mw() else 0
}

/// Fuel in online bays now, with the burn since the last settle applied.
public fun projected_fuel(entity: &Entity, clock: &Clock): u64 {
    power_grid(entity).fuel_left(clock)
}

/// Every installed bay now, with the burn since the last settle taken from the
/// online ones.
public fun projected_bays(entity: &Entity, clock: &Clock): VecMap<u64, FuelBayState> {
    let grid = power_grid(entity);
    let mut bays = grid.bays;
    take_from_online_bays(&mut bays, grid.fuel_burn(clock.timestamp_ms()));
    bays
}

/// Fuel in online bays as of the last settle, not live, with its
/// quantity-weighted stats. Empty when no online bay holds fuel. See
/// `projected_fuel` for the quantity now.
public fun online_fuel(grid: &PowerGrid): Fuel {
    let mut quantity = 0u128;
    let mut impulse = 0u128;
    let mut containment_burden = 0u128;
    let mut volatility = 0u128;
    grid.bays.length().do!(|i| {
        let (_, state) = grid.bays.get_entry_by_idx(i);
        if (state.online) {
            let held = state.fuel.quantity as u128;
            quantity = quantity + held;
            impulse = impulse + held * (state.fuel.impulse as u128);
            containment_burden =
                containment_burden + held * (state.fuel.containment_burden as u128);
            volatility = volatility + held * (state.fuel.volatility as u128);
        };
    });
    if (quantity == 0) return empty_fuel();
    Fuel {
        quantity: quantity as u64,
        impulse: (impulse / quantity) as u64,
        containment_burden: (containment_burden / quantity) as u64,
        volatility: (volatility / quantity) as u64,
    }
}

/// `(effective capacity, used MW, online module ids)` now. If the online bays
/// have run dry since the last settle, capacity, usage and every module read as `0`.
public fun projected_status(entity: &Entity, clock: &Clock): (u64, u64, vector<u64>) {
    let grid = power_grid(entity);
    if (grid.fuel_left(clock) == 0) return (0, 0, vector[]);
    (grid.effective_capacity_mw(), grid.used_mw(), grid.online_modules())
}

/// A connected module's live draw now. Zero once the online bays run dry.
public fun module_draw(entity: &Entity, module_id: u64, clock: &Clock): u64 {
    let grid = power_grid(entity);
    assert!(grid.modules.contains(&module_id), EModuleNotConnected);
    if (grid.fuel_left(clock) == 0) return 0;
    grid.live_draw(&grid.modules[&module_id])
}

/// Every connected module now. Spec and desired state stay. Draw is `0` once
/// the online bays run dry.
public fun projected_module_states(entity: &Entity, clock: &Clock): VecMap<u64, ModuleState> {
    let grid = power_grid(entity);
    let fuel_out = grid.fuel_left(clock) == 0;
    let mut states = vec_map::empty();
    grid.modules.length().do!(|i| {
        let (module_id, state) = grid.modules.get_entry_by_idx(i);
        let mut current = *state;
        current.active_draw_at_last_settled = if (fuel_out) 0 else grid.live_draw(state);
        states.insert(*module_id, current);
    });
    states
}

/// MW in use at the last settle: the sum of power modules' grants.
public fun used_mw(grid: &PowerGrid): u64 {
    let mut total = 0;
    grid.modules.length().do!(|i| {
        let (_, state) = grid.modules.get_entry_by_idx(i);
        if (state.module_spec.power_kind == PowerKind::Power) {
            total = total + state.active_draw_at_last_settled;
        };
    });
    total
}

public fun scale(): u64 {
    fuel_math::scale()
}

public fun max_connected(): u64 {
    MAX_CONNECTED
}

public fun component_id(): u64 {
    component::id_from_name(NAME)
}

public fun on(grid: &PowerGrid): bool {
    grid.on
}

/// Rated power limit: the sum of online Generators' output, plain MW. Derived
/// from the generators, not stored. `effective_capacity_mw` is what grants use.
public fun capacity_mw(grid: &PowerGrid): u64 {
    let mut total = 0;
    grid.generators.length().do!(|i| {
        let (_, state) = grid.generators.get_entry_by_idx(i);
        if (state.online) total = total + state.max_output_mw;
    });
    total
}

public fun last_settled_ms(grid: &PowerGrid): u64 {
    grid.last_settled_ms
}

public fun modules(grid: &PowerGrid): &VecMap<u64, ModuleState> {
    &grid.modules
}

public fun is_module_connected(grid: &PowerGrid, module_id: u64): bool {
    grid.modules.contains(&module_id)
}

/// A connected module's state, as of the last settle.
public fun module_state(grid: &PowerGrid, module_id: u64): ModuleState {
    assert!(grid.modules.contains(&module_id), EModuleNotConnected);
    grid.modules[&module_id]
}

public fun generators(grid: &PowerGrid): &VecMap<u64, GeneratorState> {
    &grid.generators
}

public fun stashed(grid: &PowerGrid): &VecMap<u64, Fuel> {
    &grid.stashed
}

public fun bays(grid: &PowerGrid): &VecMap<u64, FuelBayState> {
    &grid.bays
}

/// An installed fuel bay's state as of the last settle, not live.
public fun bay_state(grid: &PowerGrid, fuel_bay_id: u64): FuelBayState {
    assert!(grid.bays.contains(&fuel_bay_id), EFuelBayNotConnected);
    grid.bays[&fuel_bay_id]
}

public fun capacity(state: &FuelBayState): u64 {
    state.capacity
}

public fun bay_online(state: &FuelBayState): bool {
    state.online
}

public fun fuel(state: &FuelBayState): Fuel {
    state.fuel
}

/// Not live when read from stored state; see `Fuel`.
public fun quantity(fuel: &Fuel): u64 {
    fuel.quantity
}

public fun impulse(fuel: &Fuel): u64 {
    fuel.impulse
}

public fun containment_burden(fuel: &Fuel): u64 {
    fuel.containment_burden
}

public fun volatility(fuel: &Fuel): u64 {
    fuel.volatility
}

public fun max_output_mw(state: &GeneratorState): u64 {
    state.max_output_mw
}

public fun containment_reduction(state: &GeneratorState): u64 {
    state.containment_reduction
}

public fun base_fuel_rate(state: &GeneratorState): u64 {
    state.base_fuel_rate
}

public fun online(state: &GeneratorState): bool {
    state.online
}

public fun power_req(state: &ModuleState): u64 {
    state.module_spec.power_req
}

public fun draw_kind(state: &ModuleState): DrawKind {
    state.module_spec.draw_kind
}

public fun power_kind(state: &ModuleState): PowerKind {
    state.module_spec.power_kind
}

public fun line_loss(state: &ModuleState): u64 {
    state.module_spec.line_loss
}

public fun priority(state: &ModuleState): u64 {
    state.module_spec.priority
}

public fun desired_online(state: &ModuleState): bool {
    state.desired_online
}

public fun active_draw_at_last_settled(state: &ModuleState): u64 {
    state.active_draw_at_last_settled
}

public fun spec_power_req(module_spec: &ModulePowerSpec): u64 {
    module_spec.power_req
}

public fun spec_draw_kind(module_spec: &ModulePowerSpec): DrawKind {
    module_spec.draw_kind
}

public fun spec_power_kind(module_spec: &ModulePowerSpec): PowerKind {
    module_spec.power_kind
}

public fun spec_priority(module_spec: &ModulePowerSpec): u64 {
    module_spec.priority
}

public fun spec_line_loss(module_spec: &ModulePowerSpec): u64 {
    module_spec.line_loss
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

public fun module_id(rule: &OnlineRequirement): u64 {
    rule.module_id
}

public fun required_draw(rule: &OnlineRequirement): u64 {
    rule.draw
}

public fun required_draw_kind(rule: &OnlineRequirement): DrawKind {
    rule.draw_kind
}

public fun fuel_types(rule: &FuelRequirement): &vector<u64> {
    &rule.fuel_types
}

public fun min_impulse(rule: &FuelRequirement): Option<u64> {
    rule.min_impulse
}

public fun max_containment_burden(rule: &FuelRequirement): Option<u64> {
    rule.max_containment_burden
}

public fun min_amount(rule: &FuelRequirement): Option<u64> {
    rule.min_amount
}

public fun max_amount(rule: &FuelRequirement): Option<u64> {
    rule.max_amount
}

public fun is_fuel(kind: &PowerKind): bool {
    match (kind) {
        PowerKind::Power => false,
        PowerKind::Fuel => true,
    }
}

/// Firm MW the desired-online power modules need. Above `capacity_mw` it
/// overloads the grid and every power module goes off.
public fun desired_firm_mw(grid: &PowerGrid): u64 {
    let mut total = 0;
    grid.modules.length().do!(|i| {
        let (_, state) = grid.modules.get_entry_by_idx(i);
        if (
            state.desired_online
                && state.module_spec.power_kind == PowerKind::Power
                && state.module_spec.draw_kind == DrawKind::Firm
        ) {
            total = total + state.module_spec.power_req;
        };
    });
    total
}

/// Combined rate of desired-online fuel modules, per second at `SCALE`. They
/// burn it only while the grid is on and the online bays hold fuel.
public fun fuel_modules_rate(grid: &PowerGrid): u64 {
    let mut total = 0;
    grid.modules.length().do!(|i| {
        let (_, state) = grid.modules.get_entry_by_idx(i);
        if (state.desired_online && state.module_spec.power_kind == PowerKind::Fuel) {
            total = total + state.active_draw_at_last_settled;
        };
    });
    total
}

public fun is_firm(kind: &DrawKind): bool {
    match (kind) {
        DrawKind::Firm => true,
        DrawKind::Elastic => false,
    }
}

// === Package Functions ===

/// Borrow the grid mid-interaction and pop the next requirement.
public(package) fun take_grid<T: drop>(
    entity: &mut Entity,
    req: &mut Request,
    permit: Permit<T>,
): (Requirement, Frame, &mut PowerGrid) {
    let grid_component: &mut Component<PowerGrid> = entity.component_mut(
        req,
        power_grid_permit(),
    );
    assert!(component::version(grid_component) == VERSION, EWrongVersion);
    let grid = grid_component.inner_mut();
    let (requirement, frame) = req.take_next(permit);
    (requirement, frame, grid)
}

/// Mutable grid for install and uninstall hooks. The entity must be locked.
public(package) fun grid_mut(entity: &mut Entity): &mut PowerGrid {
    assert!(entity.has_component_with_type<PowerGrid>(component_id()), EComponentMissing);
    let grid_component: &mut Component<PowerGrid> = entity.component_mut_locked(
        component_id(),
        power_grid_permit(),
    );
    assert!(component::version(grid_component) == VERSION, EWrongVersion);
    grid_component.inner_mut()
}

/// Burn the fuel used since the last settle from the online bays. Does not
/// regrant: the caller regrants once after its change, since burn can move capacity.
public(package) fun settle(grid: &mut PowerGrid, clock: &Clock) {
    let now_ms = clock.timestamp_ms();
    let burn = grid.fuel_burn(now_ms);
    grid.last_settled_ms = now_ms.max(grid.last_settled_ms);
    take_from_online_bays(&mut grid.bays, burn);
}

/// Recompute every module's grant from desired state and effective capacity.
/// Firm desired modules gate the grid: if their costs fit, each draws its
/// `power_req`; if not, nothing draws. Desired Elastic modules share the
/// leftover in proportion to their asks, each up to its `power_req`. Emits
/// `DrawChanged` for each module whose grant moved. Walks the map by index, so
/// it costs O(n).
public(package) fun regrant(grid: &mut PowerGrid, entity_id: ID) {
    let capacity = grid.effective_capacity_mw();
    let module_count = grid.modules.length();

    let mut firm_cost = 0;
    let mut elastic_asks = 0;
    module_count.do!(|i| {
        let (_, state) = grid.modules.get_entry_by_idx(i);
        if (state.desired_online && state.module_spec.power_kind == PowerKind::Power) {
            let power_req = state.module_spec.power_req;
            if (state.module_spec.draw_kind == DrawKind::Firm) firm_cost = firm_cost + power_req
            else elastic_asks = elastic_asks + power_req;
        };
    });
    let firm_fits = firm_cost <= capacity;
    let leftover = if (firm_fits) capacity - firm_cost else 0;

    module_count.do!(|i| {
        let (module_id, state) = grid.modules.get_entry_by_idx_mut(i);
        let module_spec = state.module_spec;
        // Fuel modules keep the rate the service set.
        if (module_spec.power_kind == PowerKind::Power) {
            let mut draw = 0;
            if (state.desired_online && module_spec.draw_kind == DrawKind::Firm && firm_fits) {
                draw = module_spec.power_req;
            } else if (state.desired_online && module_spec.draw_kind == DrawKind::Elastic) {
                draw = elastic_share(module_spec.power_req, leftover, elastic_asks);
            };
            if (state.active_draw_at_last_settled != draw) {
                state.active_draw_at_last_settled = draw;
                event::emit(DrawChanged { entity_id, module_id: *module_id, active_draw: draw });
            };
        };
    });
}

/// Connect a fuel bay holding `fuel`, offline.
public(package) fun connect_fuel_bay(
    grid: &mut PowerGrid,
    fuel_bay_id: u64,
    capacity: u64,
    fuel: Fuel,
) {
    grid.bays.insert(fuel_bay_id, FuelBayState { capacity, online: false, fuel });
}

/// Disconnect a fuel bay and return its fuel. Caller settles first.
public(package) fun disconnect_fuel_bay(grid: &mut PowerGrid, fuel_bay_id: u64): Fuel {
    let (_, FuelBayState { capacity: _, online: _, fuel }) = grid.bays.remove(&fuel_bay_id);
    fuel
}

public(package) fun set_bay_online(grid: &mut PowerGrid, fuel_bay_id: u64, online: bool) {
    grid.bays[&fuel_bay_id].online = online;
}

/// Load fuel into one bay, blending its stats by quantity-weighted average.
public(package) fun blend_into_bay(grid: &mut PowerGrid, fuel_bay_id: u64, added: Fuel) {
    let fuel = &mut grid.bays[&fuel_bay_id].fuel;
    let held = fuel.quantity;
    fuel.impulse = fuel_math::blend(fuel.impulse, held, added.impulse, added.quantity);
    fuel.containment_burden =
        fuel_math::blend(
            fuel.containment_burden,
            held,
            added.containment_burden,
            added.quantity,
        );
    fuel.volatility = fuel_math::blend(fuel.volatility, held, added.volatility, added.quantity);
    fuel.quantity = held + added.quantity;
}

public(package) fun new_fuel(
    quantity: u64,
    impulse: u64,
    containment_burden: u64,
    volatility: u64,
): Fuel {
    Fuel { quantity, impulse, containment_burden, volatility }
}

/// Keep an uninstalled bay's fuel until the bay is refitted or moved.
/// Take `quantity` from the online bays in proportion to what each holds.
/// Caller settles first and checks the online bays hold enough.
public(package) fun take_from_online(grid: &mut PowerGrid, quantity: u64) {
    take_from_online_bays(&mut grid.bays, quantity);
}

fun fits_permit(): Permit<Fits> {
    internal::permit<Fits>()
}

fun shut_down_permit(): Permit<ShutDown> {
    internal::permit<ShutDown>()
}

public(package) fun withdraw_fuel_permit(): Permit<WithdrawFuel> {
    internal::permit<WithdrawFuel>()
}

public(package) fun stash_fuel(grid: &mut PowerGrid, fuel_bay_id: u64, fuel: Fuel) {
    grid.stashed.insert(fuel_bay_id, fuel);
}

/// Remove and return a bay's stashed fuel, if any.
public(package) fun take_stash(grid: &mut PowerGrid, fuel_bay_id: u64): Option<Fuel> {
    if (!grid.stashed.contains(&fuel_bay_id)) return option::none();
    let (_, fuel) = grid.stashed.remove(&fuel_bay_id);
    option::some(fuel)
}

public(package) fun empty_fuel(): Fuel {
    Fuel { quantity: 0, impulse: 0, containment_burden: 0, volatility: 0 }
}

public(package) fun connect_generator(
    grid: &mut PowerGrid,
    generator_id: u64,
    max_output_mw: u64,
    containment_reduction: u64,
    base_fuel_rate: u64,
) {
    grid
        .generators
        .insert(
            generator_id,
            GeneratorState { max_output_mw, containment_reduction, base_fuel_rate, online: false },
        );
}

/// Remove a Generator. An online Generator's output leaves `capacity_mw`.
/// Caller settles first, so burn still includes this Generator.
public(package) fun disconnect_generator(grid: &mut PowerGrid, generator_id: u64) {
    let (
        _,
        GeneratorState {
            max_output_mw: _,
            containment_reduction: _,
            base_fuel_rate: _,
            online: _,
        },
    ) = grid.generators.remove(&generator_id);
}

/// Set online state; `capacity_mw` follows from it.
public(package) fun set_generator_online(grid: &mut PowerGrid, generator_id: u64, online: bool) {
    grid.generators.get_mut(&generator_id).online = online;
}

public(package) fun connect_module(
    grid: &mut PowerGrid,
    module_id: u64,
    module_spec: ModulePowerSpec,
) {
    grid
        .modules
        .insert(
            module_id,
            ModuleState { module_spec, desired_online: false, active_draw_at_last_settled: 0 },
        );
}

/// Connect a module moved from another grid, keeping its spec and desired
/// state. It draws nothing until the caller regrants.
public(package) fun reconnect_module(grid: &mut PowerGrid, module_id: u64, state: ModuleState) {
    let ModuleState { module_spec, desired_online, active_draw_at_last_settled } = state;
    // A fuel module keeps its rate; a power module waits for the regrant.
    let draw = if (module_spec.power_kind == PowerKind::Fuel) active_draw_at_last_settled else 0;
    grid
        .modules
        .insert(
            module_id,
            ModuleState { module_spec, desired_online, active_draw_at_last_settled: draw },
        );
}

public(package) fun disconnect_module(grid: &mut PowerGrid, module_id: u64) {
    grid.modules.remove(&module_id);
}

public(package) fun set_module_priority(grid: &mut PowerGrid, module_id: u64, priority: u64) {
    grid.modules[&module_id].module_spec.priority = priority;
}

/// Switch a fuel module: online at `rate` per second (at `SCALE`), or offline.
public(package) fun set_fuel_module_rate(
    grid: &mut PowerGrid,
    module_id: u64,
    online: bool,
    rate: u64,
) {
    let state = &mut grid.modules[&module_id];
    state.desired_online = online;
    state.active_draw_at_last_settled = if (online) rate else 0;
}

public(package) fun operate_fuel_module_permit(): Permit<OperateFuelModule> {
    internal::permit<OperateFuelModule>()
}

public(package) fun set_module_desired_online(grid: &mut PowerGrid, module_id: u64, online: bool) {
    grid.modules[&module_id].desired_online = online;
}

public(package) fun manage_stash_permit(): Permit<ManageStash> {
    internal::permit<ManageStash>()
}

public(package) fun operate_grid_permit(): Permit<OperateGrid> {
    internal::permit<OperateGrid>()
}

public(package) fun online_permit(): Permit<OnlineRequirement> {
    internal::permit<OnlineRequirement>()
}

public(package) fun generator_requirement_permit(): Permit<GeneratorRequirement> {
    internal::permit<GeneratorRequirement>()
}

public(package) fun deposit_fuel_permit(): Permit<DepositFuel> {
    internal::permit<DepositFuel>()
}

public(package) fun assert_impulse_at_least(impulse: u64, min_impulse: u64) {
    assert!(impulse >= min_impulse, EImpulseBelowMin);
}

public(package) fun assert_module_connected(grid: &PowerGrid, module_id: u64) {
    assert!(grid.modules.contains(&module_id), EModuleNotConnected);
}

public(package) fun assert_fuel_bay_connected(grid: &PowerGrid, fuel_bay_id: u64) {
    assert!(grid.bays.contains(&fuel_bay_id), EFuelBayNotConnected);
}

/// Decode a `DrawKind` from its BCS enum tag.
public(package) fun draw_kind_from_tag(tag: u32): DrawKind {
    match (tag) {
        0 => DrawKind::Firm,
        1 => DrawKind::Elastic,
        _ => abort EUnknownDrawKind,
    }
}

// === Private Functions ===

/// An Elastic module's grant: its full ask while all asks fit the leftover,
/// else `leftover × ask ÷ asks`, rounded down.
fun elastic_share(ask: u64, leftover: u64, asks: u64): u64 {
    if (asks <= leftover) return ask;
    ((ask as u128) * (leftover as u128) / (asks as u128)) as u64
}

/// A module's draw as of the last settle: a power module's grant, or a fuel
/// module's rate while the grid is on.
fun live_draw(grid: &PowerGrid, state: &ModuleState): u64 {
    if (state.module_spec.power_kind == PowerKind::Fuel && !grid.on) return 0;
    state.active_draw_at_last_settled
}

/// Module ids whose live draw is nonzero and that are desired online.
fun online_modules(grid: &PowerGrid): vector<u64> {
    let mut module_ids = vector[];
    grid.modules.length().do!(|i| {
        let (module_id, state) = grid.modules.get_entry_by_idx(i);
        if (state.desired_online && grid.live_draw(state) > 0) {
            module_ids.push_back(*module_id);
        };
    });
    module_ids
}

/// Abort if the grid is short of a `PowerGridRequirement`.
fun enforce_power_grid(requirement: &Requirement, grid: &PowerGrid) {
    let mut encoded = bcs::new(requirement.data());
    let on = encoded.peel_bool();
    let fuel_quantity = encoded.peel_option_u64();
    let fuel_impulse = encoded.peel_option_u64();
    let capacity_mw = encoded.peel_u64();
    let used_mw = encoded.peel_option_u64();
    assert!(grid.on == on, EGridState);
    let fuel = grid.online_fuel();
    fuel_quantity.do!(|min_fuel| {
        let min_scaled = (min_fuel as u128) * (fuel_math::scale() as u128);
        assert!((fuel.quantity as u128) >= min_scaled, EFuelBelowMin)
    });
    fuel_impulse.do!(|min_impulse| assert!(fuel.impulse >= min_impulse, EImpulseBelowMin));
    assert!(grid.capacity_mw() >= capacity_mw, ECapacityBelowMin);
    used_mw.do!(|max_used| assert!(grid.used_mw() <= max_used, EUsedAboveMax));
}

/// Fuel in online bays now. Same number `projected_fuel` returns.
fun fuel_left(grid: &PowerGrid, clock: &Clock): u64 {
    grid.online_fuel().quantity - grid.fuel_burn(clock.timestamp_ms())
}

/// Fuel burned between `last_settled_ms` and `now_ms`, capped at what the
/// online bays hold. Each online Generator burns its share of the load at the
/// online bays' blended stats, using the grants stored at the last settle.
/// Fuel modules add their rate while the grid is on. Proportional burn keeps
/// that blend constant between settles.
fun fuel_burn(grid: &PowerGrid, now_ms: u64): u64 {
    if (now_ms <= grid.last_settled_ms) return 0;
    let capacity_mw = grid.capacity_mw();
    let load = grid.used_mw().min(capacity_mw) as u128;
    let fuel = grid.online_fuel();
    if (fuel.quantity == 0) return 0;
    let elapsed_ms = (now_ms - grid.last_settled_ms) as u128;
    let mut burn = if (grid.on) fuel_math::rate_burn(grid.fuel_modules_rate(), elapsed_ms) else 0;
    grid.generators.length().do!(|i| {
        let (_, state) = grid.generators.get_entry_by_idx(i);
        if (state.online && load > 0) {
            burn =
                burn + fuel_math::generator_burn(
                fuel.impulse,
                fuel.containment_burden,
                capacity_mw,
                state.max_output_mw,
                state.containment_reduction,
                state.base_fuel_rate,
                load,
                elapsed_ms,
            );
        };
    });
    (burn.min(fuel.quantity as u128)) as u64
}

/// Take `amount` from the online bays, each in proportion to what it holds, so
/// every bay runs dry at the same moment. The rounding remainder comes off the
/// largest online bay, then off the others in install order if that one runs
/// short. `amount` must not exceed the online bays' total.
fun take_from_online_bays(bays: &mut VecMap<u64, FuelBayState>, amount: u64) {
    if (amount == 0) return;
    let mut total = 0u128;
    bays.length().do!(|i| {
        let (_, state) = bays.get_entry_by_idx(i);
        if (state.online) total = total + (state.fuel.quantity as u128);
    });
    let mut taken = 0;
    let mut largest_idx = 0;
    let mut largest_amount = 0;
    bays.length().do!(|i| {
        let (_, state) = bays.get_entry_by_idx_mut(i);
        if (state.online && state.fuel.quantity > 0) {
            if (state.fuel.quantity > largest_amount) {
                largest_amount = state.fuel.quantity;
                largest_idx = i;
            };
            let share = ((state.fuel.quantity as u128) * (amount as u128) / total) as u64;
            state.fuel.quantity = state.fuel.quantity - share;
            taken = taken + share;
        };
    });
    let mut remainder = amount - taken;
    remainder = take_up_to(bays, largest_idx, remainder);
    bays.length().do!(|i| remainder = take_up_to(bays, i, remainder));
}

/// Take up to `remainder` from the bay at `idx` if it is online. Returns what is
/// still to take.
fun take_up_to(bays: &mut VecMap<u64, FuelBayState>, idx: u64, remainder: u64): u64 {
    if (remainder == 0) return 0;
    let (_, state) = bays.get_entry_by_idx_mut(idx);
    if (!state.online) return remainder;
    let take = remainder.min(state.fuel.quantity);
    state.fuel.quantity = state.fuel.quantity - take;
    remainder - take
}

fun component_label(): String {
    string::utf8(NAME)
}

fun power_grid_permit(): Permit<PowerGrid> {
    internal::permit<PowerGrid>()
}

fun power_grid_requirement_permit(): Permit<PowerGridRequirement> {
    internal::permit<PowerGridRequirement>()
}

// === Test Functions ===

/// `(entity_id, component_id)`.
#[test_only]
public fun installed_fields(installed: &PowerGridInstalled): (ID, u64) {
    (installed.entity_id, installed.component_id)
}

/// `(entity_id, on)`.
#[test_only]
public fun toggled_fields(toggled: &PowerToggled): (ID, bool) {
    (toggled.entity_id, toggled.on)
}

/// `(entity_id, module_id, active_draw)`.
#[test_only]
public fun draw_changed_fields(draw_changed: &DrawChanged): (ID, u64, u64) {
    (draw_changed.entity_id, draw_changed.module_id, draw_changed.active_draw)
}
