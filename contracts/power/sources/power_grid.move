/// Power grid component: one per Creation, at a well-known slot. Owns the pool
/// (fuel, capacity), the connected modules and their grants. Modules, generators
/// and fuel sources connect when installed and disconnect when uninstalled. Grants are
/// derived from each module's desired state and the live capacity at every
/// settle. Fuel deposits live in `grid_fuel`, generator state in
/// `grid_generator`, and connect, disconnect and desired state in `grid_load`. Burn math
/// lives in `fuel_math`. Every mutating path settles before it changes state.
/// Power, fuel and fuel stats are fixed point at `fuel_math::scale`. See
/// `docs/adr/0005-onchain-power-network.md`.
module power::power_grid;

use core::{
    access_cap,
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
const EPowerSourcesPresent: vector<u8> = b"Power grid still has generators or fuel sources";
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
const EFuelSourceNotConnected: vector<u8> = b"Fuel source is not connected to this power grid";
#[error(code = 13)]
const EUnknownDrawKind: vector<u8> = b"Unknown draw kind";

// === Constants ===

const VERSION: u64 = 1;
const NAME: vector<u8> = b"power_grid";
/// Cap on connected modules.
const MAX_CONNECTED: u64 = 100;

// === Structs ===

/// Pooled fuel and capacity, plus connected modules and installed generators.
public struct PowerGrid has store {
    on: bool,
    /// Fuel remaining as of `last_settled_ms`, not live. Units at `SCALE`.
    fuel_quantity_at_last_settled: u64,
    /// Sum of installed Fuel sources' capacity. Units at `SCALE`.
    fuel_capacity: u64,
    /// Blended (weighted-average) fuel impulse, at `SCALE`.
    fuel_impulse: u64,
    /// Blended (weighted-average) fuel containment burden, at `SCALE`.
    fuel_containment_burden: u64,
    /// Sum of online Generators' rated output, MW at `SCALE`.
    capacity_mw: u64,
    /// Timestamp `fuel_quantity_at_last_settled` was last computed at.
    last_settled_ms: u64,
    /// Connected modules by component id.
    modules: VecMap<u64, ModuleState>,
    /// Installed Generators by component id.
    generators: VecMap<u64, GeneratorState>,
    /// Installed Fuel sources: component id, capacity (units at `SCALE`).
    fuel_sources: VecMap<u64, u64>,
}

/// A Generator's fixed stats and online state, held by the grid.
public struct GeneratorState has copy, drop, store {
    /// MW at `SCALE`.
    max_output_mw: u64,
    /// At `SCALE`. Softens the fuel's containment burden for this Generator's burn.
    containment_reduction: u64,
    /// At `SCALE`. Units per second burned while online and the fuel has zero impulse.
    base_fuel_rate: u64,
    online: bool,
}

/// A connected module: the spec it declared, plus desired state and last-settled grant.
public struct ModuleState has copy, drop, store {
    module_spec: ModulePowerSpec,
    /// Owner intent. Set with `set_desired_state`.
    desired_online: bool,
    /// MW granted at the last settle, at `SCALE`. Zero means no grant.
    active_draw_at_last_settled: u64,
}

/// The power spec a module declares at install. Stored inside `ModuleState`.
public struct ModulePowerSpec has copy, drop, store {
    /// MW the module needs to operate, at `SCALE`.
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

/// What a module draws from. Only `Power` in v1; `Fuel` is reserved.
public enum PowerKind has copy, drop, store {
    Power,
    //TODO:  Could be Fuel later
}

/// Marker for the owner's grid operations: `set_power_grid`, `set_generator`,
/// `set_priority` and `set_desired_state`. Each also requires the owner in its
/// own frame.
public struct OperateGrid() has drop;

/// Minimum grid state an action can require. `None` skips a check.
public struct PowerGridRequirement has drop {
    on: bool,
    /// Minimum `fuel_quantity_at_last_settled`, if set.
    fuel_quantity: Option<u64>,
    /// Minimum `fuel_impulse`, if set.
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
/// or `None` skips a check. Stats and amounts at `SCALE`.
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
        fuel_quantity_at_last_settled: 0,
        fuel_capacity: 0,
        fuel_impulse: 0,
        fuel_containment_burden: 0,
        capacity_mw: 0,
        last_settled_ms: clock.timestamp_ms(),
        modules: vec_map::empty(),
        generators: vec_map::empty(),
        fuel_sources: vec_map::empty(),
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
/// Remove the grid. Aborts while any module, generator or fuel source is installed.
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
    assert!(grid.generators.is_empty() && grid.fuel_sources.is_empty(), EPowerSourcesPresent);
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

/// True if the Fuel source is installed with an installed grid.
public fun is_fuel_source_connected(entity: &Entity, fuel_id: u64): bool {
    entity.has_component_with_type<PowerGrid>(component_id())
        && power_grid(entity).fuel_sources.contains(&fuel_id)
}

/// Capacity available to grants, as of the last settle: 0 while off or out of fuel.
public fun effective_capacity_mw(grid: &PowerGrid): u64 {
    if (grid.on && grid.fuel_quantity_at_last_settled > 0) grid.capacity_mw else 0
}

/// Fuel left now, with the burn since the last settle applied.
public fun projected_fuel(entity: &Entity, clock: &Clock): u64 {
    power_grid(entity).fuel_left(clock)
}

/// `(effective capacity, used MW, online module ids)` now. If the fuel has run
/// out since the last settle, capacity, usage and every module read as `0`.
public fun projected_status(entity: &Entity, clock: &Clock): (u64, u64, vector<u64>) {
    let grid = power_grid(entity);
    if (grid.fuel_left(clock) == 0) return (0, 0, vector[]);
    (grid.effective_capacity_mw(), grid.used_mw(), grid.online_modules())
}

/// A connected module's live draw now. Zero once the fuel has run out.
public fun module_draw(entity: &Entity, module_id: u64, clock: &Clock): u64 {
    let grid = power_grid(entity);
    assert!(grid.modules.contains(&module_id), EModuleNotConnected);
    if (grid.fuel_left(clock) == 0) return 0;
    grid.modules[&module_id].active_draw_at_last_settled
}

/// Every connected module now. Spec and desired state stay. Draw is `0` once the fuel has run out.
public fun projected_module_states(entity: &Entity, clock: &Clock): VecMap<u64, ModuleState> {
    let grid = power_grid(entity);
    let fuel_out = grid.fuel_left(clock) == 0;
    let mut states = vec_map::empty();
    grid.modules.length().do!(|i| {
        let (module_id, state) = grid.modules.get_entry_by_idx(i);
        let mut current = *state;
        if (fuel_out) current.active_draw_at_last_settled = 0;
        states.insert(*module_id, current);
    });
    states
}

/// MW in use at the last settle: the sum of grants for modules with a nonzero draw.
public fun used_mw(grid: &PowerGrid): u64 {
    let mut total = 0;
    grid.modules.length().do!(|i| {
        let (_, state) = grid.modules.get_entry_by_idx(i);
        if (state.active_draw_at_last_settled > 0) {
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

public fun fuel_quantity_at_last_settled(grid: &PowerGrid): u64 {
    grid.fuel_quantity_at_last_settled
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

public fun fuel_containment_burden(grid: &PowerGrid): u64 {
    grid.fuel_containment_burden
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

public fun fuel_sources(grid: &PowerGrid): &VecMap<u64, u64> {
    &grid.fuel_sources
}

/// An installed Fuel source's capacity.
public fun fuel_source_capacity(grid: &PowerGrid, fuel_id: u64): u64 {
    assert!(grid.fuel_sources.contains(&fuel_id), EFuelSourceNotConnected);
    grid.fuel_sources[&fuel_id]
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

/// Burn the fuel used since the last settle. Does not regrant: the caller regrants
/// once after its change, since burn can move capacity.
public(package) fun settle(grid: &mut PowerGrid, clock: &Clock) {
    let now_ms = clock.timestamp_ms();
    let burn = grid.fuel_burn(now_ms);
    grid.last_settled_ms = now_ms.max(grid.last_settled_ms);
    grid.fuel_quantity_at_last_settled = grid.fuel_quantity_at_last_settled - burn;
}

/// Recompute every module's grant from desired state and effective capacity.
/// Firm desired modules gate the grid: if their costs fit, each draws its
/// `power_req`, and desired Elastic modules take the leftover in connect order.
/// If the Firm costs do not fit, nothing draws. Emits `DrawChanged` for each
/// module whose grant moved. Walks the map by index, so it costs O(n).
public(package) fun regrant(grid: &mut PowerGrid, entity_id: ID) {
    let capacity = grid.effective_capacity_mw();
    let module_count = grid.modules.length();

    let mut firm_cost = 0;
    module_count.do!(|i| {
        let (_, state) = grid.modules.get_entry_by_idx(i);
        if (state.desired_online && state.module_spec.draw_kind == DrawKind::Firm) {
            firm_cost = firm_cost + state.module_spec.power_req;
        };
    });
    let firm_fits = firm_cost <= capacity;
    let mut leftover = if (firm_fits) capacity - firm_cost else 0;

    module_count.do!(|i| {
        let (module_id, state) = grid.modules.get_entry_by_idx_mut(i);
        let module_spec = state.module_spec;
        let mut draw = 0;
        if (state.desired_online && module_spec.draw_kind == DrawKind::Firm && firm_fits) {
            draw = module_spec.power_req;
        } else if (state.desired_online
                && module_spec.draw_kind == DrawKind::Elastic
                && leftover > 0) {
            let grant = module_spec.power_req.min(leftover);
            leftover = leftover - grant;
            draw = grant;
        };
        if (state.active_draw_at_last_settled != draw) {
            state.active_draw_at_last_settled = draw;
            event::emit(DrawChanged { entity_id, module_id: *module_id, active_draw: draw });
        };
    });
}

public(package) fun connect_fuel_source(grid: &mut PowerGrid, fuel_id: u64, capacity: u64) {
    grid.fuel_sources.insert(fuel_id, capacity);
    grid.fuel_capacity = grid.fuel_capacity + capacity;
}

public(package) fun disconnect_fuel_source(grid: &mut PowerGrid, fuel_id: u64) {
    let remaining = grid.fuel_capacity - grid.fuel_sources[&fuel_id];
    grid.fuel_sources.remove(&fuel_id);
    grid.fuel_capacity = remaining;
}

public(package) fun blend_in_fuel(
    grid: &mut PowerGrid,
    amount: u64,
    impulse: u64,
    containment_burden: u64,
) {
    let old_quantity = grid.fuel_quantity_at_last_settled;
    grid.fuel_impulse = fuel_math::blend(grid.fuel_impulse, old_quantity, impulse, amount);
    grid.fuel_containment_burden =
        fuel_math::blend(
            grid.fuel_containment_burden,
            old_quantity,
            containment_burden,
            amount,
        );
    grid.fuel_quantity_at_last_settled = old_quantity + amount;
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
            max_output_mw,
            containment_reduction: _,
            base_fuel_rate: _,
            online,
        },
    ) = grid.generators.remove(&generator_id);
    if (online) {
        grid.capacity_mw = grid.capacity_mw - max_output_mw;
    };
}

/// Set online state and add or remove this Generator's output from `capacity_mw`.
public(package) fun set_generator_online(grid: &mut PowerGrid, generator_id: u64, online: bool) {
    let state = grid.generators.get_mut(&generator_id);
    state.online = online;
    let output = state.max_output_mw;
    grid.capacity_mw = if (online) grid.capacity_mw + output else grid.capacity_mw - output;
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

public(package) fun disconnect_module(grid: &mut PowerGrid, module_id: u64) {
    grid.modules.remove(&module_id);
}

public(package) fun set_module_priority(grid: &mut PowerGrid, module_id: u64, priority: u64) {
    grid.modules[&module_id].module_spec.priority = priority;
}

public(package) fun set_module_desired_online(grid: &mut PowerGrid, module_id: u64, online: bool) {
    grid.modules[&module_id].desired_online = online;
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

public(package) fun assert_fuel_source_connected(grid: &PowerGrid, fuel_id: u64) {
    assert!(grid.fuel_sources.contains(&fuel_id), EFuelSourceNotConnected);
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

/// Module ids whose live grant is nonzero and that are desired online.
fun online_modules(grid: &PowerGrid): vector<u64> {
    let mut module_ids = vector[];
    grid.modules.length().do!(|i| {
        let (module_id, state) = grid.modules.get_entry_by_idx(i);
        if (state.desired_online && state.active_draw_at_last_settled > 0) {
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
    fuel_quantity.do!(|min_fuel| {
        assert!(grid.fuel_quantity_at_last_settled >= min_fuel, EFuelBelowMin)
    });
    fuel_impulse.do!(|min_impulse| assert!(grid.fuel_impulse >= min_impulse, EImpulseBelowMin));
    assert!(grid.capacity_mw >= capacity_mw, ECapacityBelowMin);
    used_mw.do!(|max_used| assert!(grid.used_mw() <= max_used, EUsedAboveMax));
}

/// Fuel left now. Same number `projected_fuel` returns.
fun fuel_left(grid: &PowerGrid, clock: &Clock): u64 {
    grid.fuel_quantity_at_last_settled - grid.fuel_burn(clock.timestamp_ms())
}

/// Fuel burned between `last_settled_ms` and `now_ms`, capped at what is left.
/// Each online Generator burns its share of the load, using the grants stored
/// at the last settle.
fun fuel_burn(grid: &PowerGrid, now_ms: u64): u64 {
    if (now_ms <= grid.last_settled_ms) return 0;
    let load = grid.used_mw().min(grid.capacity_mw) as u128;
    if (load == 0 || grid.fuel_quantity_at_last_settled == 0) return 0;
    let elapsed_ms = (now_ms - grid.last_settled_ms) as u128;
    let mut burn = 0u128;
    grid.generators.length().do!(|i| {
        let (_, state) = grid.generators.get_entry_by_idx(i);
        if (state.online) {
            burn =
                burn + fuel_math::generator_burn(
                grid.fuel_impulse,
                grid.fuel_containment_burden,
                grid.capacity_mw,
                state.max_output_mw,
                state.containment_reduction,
                state.base_fuel_rate,
                load,
                elapsed_ms,
            );
        };
    });
    (burn.min(grid.fuel_quantity_at_last_settled as u128)) as u64
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
