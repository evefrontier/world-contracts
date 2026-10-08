/// Power grid component: one per Creation, at a well-known slot. Owns the pool
/// (fuel, capacity, used power) and is the only module that writes those numbers.
/// Fuel deposits live in `grid_fuel`, generator on/off in `grid_generator`, and
/// reserve/release in `grid_load`. Burn math lives in `fuel_math`. Every mutating
/// path settles here before it changes the pool. Power, fuel and fuel stats are
/// fixed point at `fuel_math::scale`. See `docs/adr/0005-onchain-power-network.md`.
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
const EModulesRegistered: vector<u8> = b"Power grid still has registered modules";
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
const EModuleNotRegistered: vector<u8> = b"Module is not registered with this power grid";
#[error(code = 12)]
const ENotConnected: vector<u8> = b"Module is not connected to this power grid";
#[error(code = 13)]
const EFuelSourceNotRegistered: vector<u8> = b"Fuel source is not registered with this power grid";
#[error(code = 14)]
const EUsageExceedsReservations: vector<u8> =
    b"Grid usage is above capacity with no reservation left to shed";

// === Constants ===

const VERSION: u64 = 1;
const NAME: vector<u8> = b"power_grid";
/// Cap on registered modules.
const MAX_CONNECTED: u64 = 100;

// === Structs ===

/// Pooled fuel and capacity, plus connected modules and their reservations.
public struct PowerGrid has store {
    on: bool,
    /// Fuel remaining as of `last_settled_ms`, not live. Units at `SCALE`.
    settled_fuel_quantity: u64,
    /// Sum of registered Fuel sources' capacity. Units at `SCALE`.
    fuel_capacity: u64,
    /// Blended (weighted-average) fuel impulse, at `SCALE`.
    fuel_impulse: u64,
    /// Blended (weighted-average) fuel containment burden, at `SCALE`.
    fuel_containment_burden: u64,
    /// Sum of online Generators' rated output, MW at `SCALE`.
    capacity_mw: u64,
    /// Sum of granted reservations' `active_draw + line_loss`, MW at `SCALE`.
    used_mw: u64,
    /// Timestamp `settled_fuel_quantity` was last computed at.
    last_settled_ms: u64,
    /// Connected modules by component id: line loss, priority group and reservation.
    modules: VecMap<u64, ModuleState>,
    /// Generators feeding the grid by component id.
    generators: VecMap<u64, GeneratorState>,
    /// Fuel sources feeding the grid: component id, capacity (units at `SCALE`).
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

/// A connected module's admin-set line loss, priority group and reservation, if any.
public struct ModuleState has copy, drop, store {
    /// MW of overhead the module costs the grid while granted.
    line_loss: u64,
    /// Priority group. A higher group number is shed first. Group 0 is last.
    priority: u64,
    reservation: Option<Reservation>,
}

/// One module's power ask and its current grant.
public struct Reservation has copy, drop, store {
    /// MW asked.
    requested: u64,
    /// MW granted: `requested` for Firm, up to `requested` for Elastic.
    active_draw: u64,
    kind: DrawKind,
}

/// How a reservation is granted: Firm is all-or-nothing, Elastic takes leftover.
public enum DrawKind has copy, drop, store {
    Firm,
    Elastic,
}

/// Marker for `register_generator` / `unregister_generator`.
public struct ManageGenerator() has drop;

/// Marker for the owner's grid operations: `set_power_grid`, `set_generator`,
/// `set_priority`, `reserve`, `release` and `release_priority`. Each also
/// requires the owner in its own frame.
public struct OperateGrid() has drop;

/// Marker for `connect_module` / `disconnect_module`.
public struct ManageModule() has drop;

/// Marker for `register_fuel_source` / `unregister_fuel_source`.
public struct ManageFuel() has drop;

/// Minimum grid state an action can require. `None` skips a check.
public struct PowerGridRequirement has drop {
    on: bool,
    /// Minimum `settled_fuel_quantity`, if set.
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

/// `module_id` holds a reservation of `kind` with at least `draw` MW granted.
public struct ReserveRequirement has drop {
    module_id: u64,
    draw: u64,
    kind: DrawKind,
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

/// A reservation was released because capacity dropped below usage.
public struct Shed has copy, drop {
    entity_id: ID,
    module_id: u64,
}

/// Settling burned the last of the fuel.
public struct FuelDepleted has copy, drop {
    entity_id: ID,
}

// === Public Functions ===

/// Install the grid, off and empty. Admin-gated.
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
/// Remove the grid. Aborts while anything is registered or connected.
public fun uninstall(entity: &mut Entity, ctx: &mut TxContext): Request {
    assert!(entity.has_component_with_type<PowerGrid>(component_id()), EComponentMissing);

    let (grid_component, req) = entity.uninstall<PowerGrid>(
        component_id(),
        power_grid_permit(),
        ctx,
    );
    assert!(component::version(&grid_component) == VERSION, EWrongVersion);
    let grid = grid_component.unwrap(power_grid_permit());
    assert!(grid.modules.is_empty(), EModulesRegistered);
    assert!(grid.generators.is_empty() && grid.fuel_sources.is_empty(), EPowerSourcesPresent);
    let PowerGrid { .. } = grid;
    event::emit(PowerGridUninstalled { entity_id: entity.id(), component_id: component_id() });
    req
}

// TODO: This power grid level shut down and on
/// Switch the grid on or off.
public fun set_power_grid(entity: &mut Entity, req: &mut Request, on: bool, clock: &Clock) {
    let entity_id = entity.id();
    let (_requirement, mut frame, grid) = take_grid(entity, req, operate_grid_permit());
    if (on) assert!(!grid.on, EAlreadyOn) else assert!(grid.on, EAlreadyOff);
    grid.settle(entity_id, clock);
    grid.on = on;
    event::emit(PowerToggled { entity_id, on });
    grid.shed(entity_id);
    frame.require(access_cap::owner_requirement());
    req.enqueue(frame);
}

/// Requirement satisfied by `set_power_grid`, `set_generator`, `set_priority`,
/// `reserve`, `release` and `release_priority`; one per call.
public fun operate_grid_requirement(): Requirement {
    requirement::from_config(option::some(component_id()), OperateGrid())
}

/// Requirement satisfied by `register_generator` / `unregister_generator`.
public fun manage_generator_requirement(): Requirement {
    requirement::from_config(option::some(component_id()), ManageGenerator())
}

/// Requirement satisfied by `connect_module` / `disconnect_module`.
public fun manage_module_requirement(): Requirement {
    requirement::from_config(option::some(component_id()), ManageModule())
}

/// Requirement satisfied by `register_fuel_source` / `unregister_fuel_source`.
public fun manage_fuel_requirement(): Requirement {
    requirement::from_config(option::some(component_id()), ManageFuel())
}

/// Abort unless the grid meets the next `PowerGridRequirement`.
/// Settles first, so burned fuel counts before the check.
public fun assert_power_grid(entity: &mut Entity, req: &mut Request, clock: &Clock) {
    let entity_id = entity.id();
    let (requirement, frame, grid) = take_grid(entity, req, power_grid_requirement_permit());
    grid.settle(entity_id, clock);
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

/// Build a `ReserveRequirement` for `module_id`.
public fun reserve_requirement(module_id: u64, draw: u64, kind: DrawKind): Requirement {
    requirement::from_config(
        option::some(component_id()),
        ReserveRequirement { module_id, draw, kind },
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

/// Firm: all or nothing.
public fun firm(): DrawKind { DrawKind::Firm }

/// Elastic: up to the ask, from what is left.
public fun elastic(): DrawKind { DrawKind::Elastic }

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

/// A registered Generator's state.
public fun generator_state(entity: &Entity, generator_id: u64): GeneratorState {
    generator::assert_installed(entity, generator_id);
    *power_grid(entity).generators.get(&generator_id)
}

/// True if the Generator is registered with an installed grid.
public fun is_generator_registered(entity: &Entity, generator_id: u64): bool {
    entity.has_component_with_type<PowerGrid>(component_id())
        && power_grid(entity).generators.contains(&generator_id)
}

/// True if the Fuel source is registered with an installed grid.
public fun is_fuel_source_registered(entity: &Entity, fuel_id: u64): bool {
    entity.has_component_with_type<PowerGrid>(component_id())
        && power_grid(entity).fuel_sources.contains(&fuel_id)
}

/// Capacity available to reservations, as of the last settle: 0 while off or out of fuel.
public fun effective_capacity_mw(grid: &PowerGrid): u64 {
    if (grid.on && grid.settled_fuel_quantity > 0) grid.capacity_mw else 0
}

/// Fuel left now, with the burn since the last settle applied.
public fun projected_fuel(grid: &PowerGrid, clock: &Clock): u64 {
    grid.settled_fuel_quantity - grid.fuel_burn(clock.timestamp_ms())
}

// TODO: Should we have a update function that can be called by the owner if he wants spend for upto date values ?
/// `(effective_capacity_mw, used_mw, reserved module ids)` now. If the fuel
/// has run out since the last settle, everything reads as shed.
public fun projected_status(grid: &PowerGrid, clock: &Clock): (u64, u64, vector<u64>) {
    if (grid.projected_fuel(clock) == 0) return (0, 0, vector[]);
    (grid.effective_capacity_mw(), grid.used_mw, grid.reserved_modules())
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

public fun modules(grid: &PowerGrid): &VecMap<u64, ModuleState> {
    &grid.modules
}

public fun is_module_registered(grid: &PowerGrid, module_id: u64): bool {
    grid.modules.contains(&module_id)
}

/// A registered module's state.
public fun module_state(grid: &PowerGrid, module_id: u64): ModuleState {
    assert!(grid.modules.contains(&module_id), EModuleNotRegistered);
    grid.modules[&module_id]
}

public fun is_connected(grid: &PowerGrid, module_id: u64): bool {
    grid.modules.contains(&module_id)
}

/// The priority group of a connected module.
public fun priority(grid: &PowerGrid, module_id: u64): u64 {
    assert!(grid.modules.contains(&module_id), ENotConnected);
    grid.modules[&module_id].priority
}

public fun has_reservation(grid: &PowerGrid, module_id: u64): bool {
    grid.modules.contains(&module_id) && grid.modules[&module_id].reservation.is_some()
}

public fun generators(grid: &PowerGrid): &VecMap<u64, GeneratorState> {
    &grid.generators
}

public fun fuel_sources(grid: &PowerGrid): &VecMap<u64, u64> {
    &grid.fuel_sources
}

/// A registered Fuel source's capacity.
public fun fuel_source_capacity(grid: &PowerGrid, fuel_id: u64): u64 {
    assert!(grid.fuel_sources.contains(&fuel_id), EFuelSourceNotRegistered);
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

public fun line_loss(state: &ModuleState): u64 {
    state.line_loss
}

public fun reservation(state: &ModuleState): Option<Reservation> {
    state.reservation
}

public fun requested(reservation: &Reservation): u64 {
    reservation.requested
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

public fun reserve_module_id(rule: &ReserveRequirement): u64 {
    rule.module_id
}

public fun required_draw(rule: &ReserveRequirement): u64 {
    rule.draw
}

public fun required_kind(rule: &ReserveRequirement): DrawKind {
    rule.kind
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

/// Burn the fuel used since the last settle and advance to now. Running dry
/// zeroes effective capacity, so every reservation is shed.
public(package) fun settle(grid: &mut PowerGrid, entity_id: ID, clock: &Clock) {
    let now_ms = clock.timestamp_ms();
    let burn = grid.fuel_burn(now_ms);
    grid.last_settled_ms = now_ms.max(grid.last_settled_ms);
    if (burn == 0) return;
    grid.settled_fuel_quantity = grid.settled_fuel_quantity - burn;
    if (grid.settled_fuel_quantity == 0) {
        event::emit(FuelDepleted { entity_id });
        grid.shed(entity_id);
    };
}

/// Release reservations until usage fits. Usable power of 0 releases every
/// reservation in one pass. Otherwise whole priority groups go, highest
/// group number first. Group 0 is last. Stays here because `settle` calls it.
public(package) fun shed(grid: &mut PowerGrid, entity_id: ID) {
    if (grid.effective_capacity_mw() == 0) {
        grid.reserved_modules().do!(|module_id| {
            grid.release_module(module_id);
            event::emit(Shed { entity_id, module_id });
        });
        return
    };
    while (grid.used_mw > grid.effective_capacity_mw()) {
        let mut highest = 0;
        grid.modules.length().do!(|i| {
            let (_, state) = grid.modules.get_entry_by_idx(i);
            if (state.reservation.is_some() && state.priority > highest) highest = state.priority;
        });
        let module_ids = grid.reserved_at(highest);
        assert!(!module_ids.is_empty(), EUsageExceedsReservations);
        module_ids.do!(|module_id| {
            grid.release_module(module_id);
            event::emit(Shed { entity_id, module_id });
        });
    };
}

/// Drop `module_id`'s reservation and free its draw and line loss.
public(package) fun release_module(grid: &mut PowerGrid, module_id: u64) {
    let state = &mut grid.modules[&module_id];
    let reservation = state.reservation.extract();
    grid.used_mw = grid.used_mw - (reservation.active_draw + state.line_loss);
}

/// Module ids with a reservation in priority group `priority`.
public(package) fun reserved_at(grid: &PowerGrid, priority: u64): vector<u64> {
    let mut module_ids = vector[];
    grid.modules.length().do!(|i| {
        let (module_id, state) = grid.modules.get_entry_by_idx(i);
        if (state.reservation.is_some() && state.priority == priority) {
            module_ids.push_back(*module_id);
        };
    });
    module_ids
}

public(package) fun insert_fuel_source(grid: &mut PowerGrid, fuel_id: u64, capacity: u64) {
    grid.fuel_sources.insert(fuel_id, capacity);
    grid.fuel_capacity = grid.fuel_capacity + capacity;
}

public(package) fun remove_fuel_source(grid: &mut PowerGrid, fuel_id: u64) {
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
    let old_quantity = grid.settled_fuel_quantity;
    grid.fuel_impulse = fuel_math::blend(grid.fuel_impulse, old_quantity, impulse, amount);
    grid.fuel_containment_burden =
        fuel_math::blend(
            grid.fuel_containment_burden,
            old_quantity,
            containment_burden,
            amount,
        );
    grid.settled_fuel_quantity = old_quantity + amount;
}

public(package) fun insert_generator(
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

public(package) fun remove_generator(grid: &mut PowerGrid, generator_id: u64) {
    grid.generators.remove(&generator_id);
}

/// Set online state and add or remove this Generator's output from `capacity_mw`.
public(package) fun apply_generator_online(grid: &mut PowerGrid, generator_id: u64, online: bool) {
    let state = grid.generators.get_mut(&generator_id);
    state.online = online;
    let output = state.max_output_mw;
    grid.capacity_mw = if (online) grid.capacity_mw + output else grid.capacity_mw - output;
}

public(package) fun insert_module(grid: &mut PowerGrid, module_id: u64, line_loss: u64) {
    grid
        .modules
        .insert(
            module_id,
            ModuleState { line_loss, priority: 0, reservation: option::none() },
        );
}

public(package) fun remove_module(grid: &mut PowerGrid, module_id: u64) {
    grid.modules.remove(&module_id);
}

public(package) fun set_module_priority(grid: &mut PowerGrid, module_id: u64, priority: u64) {
    grid.modules[&module_id].priority = priority;
}

public(package) fun grant_reservation(
    grid: &mut PowerGrid,
    module_id: u64,
    requested: u64,
    active_draw: u64,
    kind: DrawKind,
) {
    let state = &mut grid.modules[&module_id];
    grid.used_mw = grid.used_mw + active_draw + state.line_loss;
    state.reservation.fill(Reservation { requested, active_draw, kind });
}

public(package) fun operate_grid_permit(): Permit<OperateGrid> {
    internal::permit<OperateGrid>()
}

public(package) fun manage_generator_permit(): Permit<ManageGenerator> {
    internal::permit<ManageGenerator>()
}

public(package) fun generator_requirement_permit(): Permit<GeneratorRequirement> {
    internal::permit<GeneratorRequirement>()
}

public(package) fun manage_module_permit(): Permit<ManageModule> {
    internal::permit<ManageModule>()
}

public(package) fun reserve_permit(): Permit<ReserveRequirement> {
    internal::permit<ReserveRequirement>()
}

public(package) fun manage_fuel_permit(): Permit<ManageFuel> {
    internal::permit<ManageFuel>()
}

public(package) fun deposit_fuel_permit(): Permit<DepositFuel> {
    internal::permit<DepositFuel>()
}

public(package) fun assert_impulse_at_least(impulse: u64, min_impulse: u64) {
    assert!(impulse >= min_impulse, EImpulseBelowMin);
}

public(package) fun assert_module_registered(grid: &PowerGrid, module_id: u64) {
    assert!(grid.modules.contains(&module_id), EModuleNotRegistered);
}

public(package) fun assert_connected(grid: &PowerGrid, module_id: u64) {
    assert!(grid.modules.contains(&module_id), ENotConnected);
}

public(package) fun assert_fuel_source_registered(grid: &PowerGrid, fuel_id: u64) {
    assert!(grid.fuel_sources.contains(&fuel_id), EFuelSourceNotRegistered);
}

// === Private Functions ===

/// Module ids that hold a reservation, in connect order.
fun reserved_modules(grid: &PowerGrid): vector<u64> {
    let mut module_ids = vector[];
    grid.modules.length().do!(|i| {
        let (module_id, state) = grid.modules.get_entry_by_idx(i);
        if (state.reservation.is_some()) module_ids.push_back(*module_id);
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
    fuel_quantity.do!(|min_fuel| assert!(grid.settled_fuel_quantity >= min_fuel, EFuelBelowMin));
    fuel_impulse.do!(|min_impulse| assert!(grid.fuel_impulse >= min_impulse, EImpulseBelowMin));
    assert!(grid.capacity_mw >= capacity_mw, ECapacityBelowMin);
    used_mw.do!(|max_used| assert!(grid.used_mw <= max_used, EUsedAboveMax));
}

/// Fuel burned between `last_settled_ms` and `now_ms`, capped at what is left.
/// Each online Generator burns its share of the load.
fun fuel_burn(grid: &PowerGrid, now_ms: u64): u64 {
    if (now_ms <= grid.last_settled_ms) return 0;
    let load = grid.used_mw.min(grid.capacity_mw) as u128;
    if (load == 0 || grid.settled_fuel_quantity == 0) return 0;
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
    (burn.min(grid.settled_fuel_quantity as u128)) as u64
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
public fun installed_fields(e: &PowerGridInstalled): (ID, u64) {
    (e.entity_id, e.component_id)
}

/// `(entity_id, on)`.
#[test_only]
public fun toggled_fields(e: &PowerToggled): (ID, bool) {
    (e.entity_id, e.on)
}

/// `(entity_id, module_id)`.
#[test_only]
public fun shed_fields(e: &Shed): (ID, u64) {
    (e.entity_id, e.module_id)
}
