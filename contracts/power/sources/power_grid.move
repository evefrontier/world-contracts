/// Power grid component: one per Creation, at a well-known slot. Pools
/// Generator capacity and fuel, and grants Firm or Elastic power draws to
/// connected modules. Fuel burns lazily: every mutating handler settles the
/// burn since the last touch, and views project it to now. Power, fuel and
/// fuel stats are fixed point at `SCALE`. See `docs/adr/0005-onchain-power-network.md`.
module power::power_grid;

use core::{
    admin_service,
    component::{Self, Component},
    entity::Entity,
    request::{Request, Frame},
    requirement::{Self, Requirement}
};
use power::{fuel, generator};
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
const EUsedAboveMax: vector<u8> = b"Used power is above the requirement";
#[error(code = 17)]
const EGenNotOnline: vector<u8> = b"Generator is not online";
#[error(code = 18)]
const EOutputBelowMin: vector<u8> = b"Generator output is below the requirement";
#[error(code = 19)]
const EContainmentBelowMin: vector<u8> = b"Containment reduction is below the requirement";
#[error(code = 20)]
const EModuleMissing: vector<u8> = b"Module component is not installed on this entity";
#[error(code = 21)]
const EModuleAlreadyRegistered: vector<u8> = b"Module is already registered with this power grid";
#[error(code = 22)]
const EModuleNotRegistered: vector<u8> = b"Module is not registered with this power grid";
#[error(code = 23)]
const ETooManyConnected: vector<u8> = b"Power grid has reached its maximum connected modules";
#[error(code = 24)]
const ENotConnected: vector<u8> = b"Module is not connected to this power grid";
#[error(code = 25)]
const EAlreadyReserved: vector<u8> = b"Module already has a power reservation";
#[error(code = 26)]
const ENotReserved: vector<u8> = b"Module has no power reservation";
#[error(code = 27)]
const EZeroDraw: vector<u8> = b"Power draw must be greater than zero";
#[error(code = 28)]
const EUnknownDrawKind: vector<u8> = b"Unknown draw kind";
#[error(code = 29)]
const EInsufficientPower: vector<u8> = b"Power grid does not have enough capacity for this draw";
#[error(code = 30)]
const EDrawBelowMin: vector<u8> = b"Module's granted draw is below the requirement";
#[error(code = 31)]
const EDrawKindMismatch: vector<u8> = b"Module's draw kind does not match the requirement";
#[error(code = 32)]
const EFuelSourceAlreadyRegistered: vector<u8> =
    b"Fuel source is already registered with this power grid";
#[error(code = 33)]
const EFuelSourceNotRegistered: vector<u8> = b"Fuel source is not registered with this power grid";
#[error(code = 34)]
const EFuelSourceStillRegistered: vector<u8> =
    b"Fuel source must be unregistered from the power grid before uninstall";
#[error(code = 35)]
const EFuelOverCapacity: vector<u8> = b"Fuel quantity would exceed the grid's fuel capacity";
#[error(code = 36)]
const EZeroFuel: vector<u8> = b"Fuel amount must be greater than zero";
#[error(code = 37)]
const EFuelTypeNotAllowed: vector<u8> = b"Fuel type is not allowed by the requirement";
#[error(code = 38)]
const EBurdenAboveMax: vector<u8> = b"Fuel containment burden is above the requirement";
#[error(code = 39)]
const EFuelAmountBelowMin: vector<u8> = b"Fuel amount is below the requirement";
#[error(code = 40)]
const EFuelAmountAboveMax: vector<u8> = b"Fuel amount is above the requirement";
#[error(code = 41)]
const EOutOfFuel: vector<u8> = b"Power grid has run out of fuel";

// === Constants ===

const VERSION: u64 = 1;
const NAME: vector<u8> = b"power_grid";
/// Cap on registered modules.
const MAX_CONNECTED: u64 = 100;
/// Fixed-point scale for power, fuel and fuel stats: 4 decimals.
const SCALE: u64 = 10_000;
const MS_PER_SECOND: u64 = 1_000;
/// Fuel factor bounds, matching the game client: [1, 100] at `SCALE`.
const MIN_FUEL_FACTOR: u64 = 10_000;
const MAX_FUEL_FACTOR: u64 = 1_000_000;

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
    /// Registered modules by component id: line loss and reservation.
    modules: VecMap<u64, ModuleState>,
    // TODO: this can gain a category later, with the priority group as a sibling of it.
    /// Connected modules: component id, priority group. A higher group number is shed first. Group 0 is last.
    connected: VecMap<u64, u64>,
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
    online: bool,
}

/// A registered module's admin-set line loss and its reservation, if any.
public struct ModuleState has copy, drop, store {
    /// MW of overhead the module costs the grid while granted.
    line_loss: u64,
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
/// `set_priority`, `reserve`, `release` and `release_priority`.
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

/// The grid's `capacity_mw` changed.
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

public struct ModuleConnected has copy, drop {
    entity_id: ID,
    module_id: u64,
    line_loss: u64,
    /// Priority group. A new connection starts in group 0.
    priority: u64,
}

public struct ModuleDisconnected has copy, drop {
    entity_id: ID,
    module_id: u64,
}

public struct PriorityChanged has copy, drop {
    entity_id: ID,
    module_id: u64,
    /// Priority group the module moved into.
    priority: u64,
}

/// A reservation was granted.
public struct Reserved has copy, drop {
    entity_id: ID,
    module_id: u64,
    kind: DrawKind,
    requested: u64,
    line_loss: u64,
    active_draw: u64,
}

public struct Released has copy, drop {
    entity_id: ID,
    module_id: u64,
}

/// A reservation was released because capacity dropped below usage.
public struct Shed has copy, drop {
    entity_id: ID,
    module_id: u64,
}

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
        connected: vec_map::empty(),
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
    let (_requirement, frame, grid) = take(entity, req, operate_grid_permit());
    if (on) assert!(!grid.on, EAlreadyOn) else assert!(grid.on, EAlreadyOff);
    grid.settle(entity_id, clock);
    grid.on = on;
    event::emit(PowerToggled { entity_id, on });
    grid.shed(entity_id);
    frame.destroy_empty_frame();
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
    let (requirement, frame, grid) = take(entity, req, power_grid_requirement_permit());
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

/// Register an installed Generator with its stats, offline. Admin-only.
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
    grid.settle(entity_id, clock);
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

/// Remove an offline Generator from the grid. Admin-only.
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
    grid.settle(entity_id, clock);
    grid.generators.remove(&generator_id);
    event::emit(GeneratorUnregistered { entity_id, generator_id });
    frame.require(admin_service::admin_requirement());
    req.enqueue(frame);
}

/// Uninstall an unregistered Generator. Admin-gated.
public fun uninstall_generator(
    entity: &mut Entity,
    generator_id: u64,
    ctx: &mut TxContext,
): Request {
    // TODO: we can automatically offline and unregister if needed
    assert!(!is_generator_registered(entity, generator_id), EGeneratorStillRegistered);
    generator::uninstall(entity, generator_id, ctx)
}

/// Bring a Generator online or offline.
public fun set_generator(
    entity: &mut Entity,
    req: &mut Request,
    generator_id: u64,
    online: bool,
    clock: &Clock,
) {
    let entity_id = entity.id();
    let (_requirement, frame, grid) = take(entity, req, operate_grid_permit());
    grid.set_generator_online(entity_id, generator_id, online, clock);
    frame.destroy_empty_frame();
}

/// Abort unless a Generator meets the next `GeneratorRequirement`.
public fun assert_generator(entity: &mut Entity, req: &mut Request) {
    let (requirement, frame, grid) = take(entity, req, generator_requirement_permit());
    enforce_generator(&requirement, grid);
    frame.destroy_empty_frame();
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

/// Connect an installed module to the grid in priority group 0, with its line loss. Admin-only.
public fun connect_module(
    entity: &mut Entity,
    req: &mut Request,
    module_id: u64,
    line_loss: u64,
    clock: &Clock,
) {
    assert!(entity.has_component(module_id), EModuleMissing);
    let entity_id = entity.id();
    let (_requirement, mut frame, grid) = take(entity, req, manage_module_permit());
    assert!(!grid.modules.contains(&module_id), EModuleAlreadyRegistered);
    assert!(grid.modules.length() < MAX_CONNECTED, ETooManyConnected);
    grid.settle(entity_id, clock);
    grid.modules.insert(module_id, ModuleState { line_loss, reservation: option::none() });
    grid.connected.insert(module_id, 0);
    event::emit(ModuleConnected { entity_id, module_id, line_loss, priority: 0 });
    frame.require(admin_service::admin_requirement());
    req.enqueue(frame);
}

/// Disconnect a module from the grid, releasing its reservation if any. Admin-only.
public fun disconnect_module(
    entity: &mut Entity,
    req: &mut Request,
    module_id: u64,
    clock: &Clock,
) {
    let entity_id = entity.id();
    let (_requirement, mut frame, grid) = take(entity, req, manage_module_permit());
    assert!(grid.modules.contains(&module_id), EModuleNotRegistered);
    grid.settle(entity_id, clock);
    if (grid.has_reservation(module_id)) {
        grid.release_module(module_id);
        event::emit(Released { entity_id, module_id });
    };
    grid.modules.remove(&module_id);
    if (grid.connected.contains(&module_id)) {
        grid.connected.remove(&module_id);
    };
    event::emit(ModuleDisconnected { entity_id, module_id });
    frame.require(admin_service::admin_requirement());
    req.enqueue(frame);
}

/// Move a connected module into priority group `priority`.
public fun set_priority(
    entity: &mut Entity,
    req: &mut Request,
    module_id: u64,
    priority: u64,
    clock: &Clock,
) {
    let entity_id = entity.id();
    let (_requirement, frame, grid) = take(entity, req, operate_grid_permit());
    assert!(grid.connected.contains(&module_id), ENotConnected);
    grid.settle(entity_id, clock);
    *&mut grid.connected[&module_id] = priority;
    event::emit(PriorityChanged { entity_id, module_id, priority });
    frame.destroy_empty_frame();
}

/// Reserve `draw` MW of `kind` for `module_id`. Aborts if it does not fit.
public fun reserve(
    entity: &mut Entity,
    req: &mut Request,
    module_id: u64,
    draw: u64,
    kind: DrawKind,
    clock: &Clock,
) {
    let entity_id = entity.id();
    let (_requirement, frame, grid) = take(entity, req, operate_grid_permit());
    assert!(draw > 0, EZeroDraw);
    assert!(grid.connected.contains(&module_id), ENotConnected);
    // TODO: may later replace the existing reservation instead of aborting.
    assert!(!grid.has_reservation(module_id), EAlreadyReserved);
    grid.settle(entity_id, clock);
    let line_loss = grid.modules[&module_id].line_loss;
    let effective = grid.effective_capacity_mw();
    let leftover = if (effective > grid.used_mw) effective - grid.used_mw else 0;
    assert!(leftover > line_loss, EInsufficientPower);
    let active_draw = if (kind.is_firm()) draw else draw.min(leftover - line_loss);
    assert!(active_draw + line_loss <= leftover, EInsufficientPower);
    grid.used_mw = grid.used_mw + active_draw + line_loss;
    grid.modules[&module_id].reservation.fill(Reservation { requested: draw, active_draw, kind });
    event::emit(Reserved { entity_id, module_id, kind, requested: draw, line_loss, active_draw });
    frame.destroy_empty_frame();
}

/// Release `module_id`'s reservation.
public fun release(entity: &mut Entity, req: &mut Request, module_id: u64, clock: &Clock) {
    let entity_id = entity.id();
    let (_requirement, frame, grid) = take(entity, req, operate_grid_permit());
    assert!(grid.has_reservation(module_id), ENotReserved);
    grid.settle(entity_id, clock);
    grid.release_module(module_id);
    event::emit(Released { entity_id, module_id });
    frame.destroy_empty_frame();
}

/// Release every reservation in priority group `priority`.
public fun release_priority(entity: &mut Entity, req: &mut Request, priority: u64, clock: &Clock) {
    let entity_id = entity.id();
    let (_requirement, frame, grid) = take(entity, req, operate_grid_permit());
    grid.settle(entity_id, clock);
    grid.reserved_at(priority).do!(|module_id| {
        grid.release_module(module_id);
        event::emit(Released { entity_id, module_id });
    });
    frame.destroy_empty_frame();
}

/// Abort unless the module in the next `ReserveRequirement` still holds a
/// matching reservation. Settles first, so a grid that ran out of fuel since
/// the last touch fails here instead of passing on stale state.
public fun assert_reserved(entity: &mut Entity, req: &mut Request, clock: &Clock) {
    let entity_id = entity.id();
    let (requirement, frame, grid) = take(entity, req, reserve_permit());
    grid.settle(entity_id, clock);
    assert!(grid.settled_fuel_quantity > 0, EOutOfFuel);
    enforce_reserved(&requirement, grid);
    frame.destroy_empty_frame();
}

/// Build a `ReserveRequirement` for `module_id`.
public fun reserve_requirement(module_id: u64, draw: u64, kind: DrawKind): Requirement {
    requirement::from_config(
        option::some(component_id()),
        ReserveRequirement { module_id, draw, kind },
    )
}

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
    let (_requirement, mut frame, grid) = take(entity, req, manage_fuel_permit());
    assert!(!grid.fuel_sources.contains(&fuel_id), EFuelSourceAlreadyRegistered);
    grid.settle(entity_id, clock);
    grid.fuel_sources.insert(fuel_id, capacity);
    grid.fuel_capacity = grid.fuel_capacity + capacity;
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
    let (_requirement, mut frame, grid) = take(entity, req, manage_fuel_permit());
    assert!(grid.fuel_sources.contains(&fuel_id), EFuelSourceNotRegistered);
    grid.settle(entity_id, clock);
    let remaining = grid.fuel_capacity - grid.fuel_sources[&fuel_id];
    assert!(grid.settled_fuel_quantity <= remaining, EFuelOverCapacity);
    grid.fuel_sources.remove(&fuel_id);
    grid.fuel_capacity = remaining;
    event::emit(FuelSourceUnregistered { entity_id, fuel_id });
    frame.require(admin_service::admin_requirement());
    req.enqueue(frame);
}

/// Uninstall an unregistered Fuel source. Admin-gated.
public fun uninstall_fuel_source(entity: &mut Entity, fuel_id: u64, ctx: &mut TxContext): Request {
    assert!(!is_fuel_source_registered(entity, fuel_id), EFuelSourceStillRegistered);
    fuel::uninstall(entity, fuel_id, ctx)
}

// TODO: an `Item`to fuel path once inventory can connect to the fuel bay.
/// Bridge `amount` of fuel into the pool and blend its stats by weighted
/// average, if it meets the owner's `FuelRequirement`. All values at `SCALE`,
/// supplied by the game server. The gas sponsor must be on `AdminACL`.
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
    let (requirement, mut frame, grid) = take(entity, req, deposit_fuel_permit());
    assert!(amount > 0, EZeroFuel);
    enforce_fuel(&requirement, fuel_type, amount, impulse, containment_burden);
    grid.settle(entity_id, clock);
    let old_quantity = grid.settled_fuel_quantity;
    assert!(old_quantity + amount <= grid.fuel_capacity, EFuelOverCapacity);
    grid.fuel_impulse = blend(grid.fuel_impulse, old_quantity, impulse, amount);
    grid.fuel_containment_burden =
        blend(grid.fuel_containment_burden, old_quantity, containment_burden, amount);
    grid.settled_fuel_quantity = old_quantity + amount;
    event::emit(FuelAdded {
        entity_id,
        fuel_type,
        amount,
        resulting_quantity: grid.settled_fuel_quantity,
        resulting_impulse: grid.fuel_impulse,
        resulting_containment_burden: grid.fuel_containment_burden,
    });
    frame.require(admin_service::sponsor_requirement());
    req.enqueue(frame);
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

/// Fuel burned per second of load: `impulse / max(1, burden / containment_reduction)`,
/// clamped to [1, 100]. All values at `SCALE`.
public fun fuel_factor(impulse: u64, containment_burden: u64, containment_reduction: u64): u64 {
    let reduction = containment_reduction.max(SCALE) as u128;
    let burden_ratio = ((containment_burden as u128) * (SCALE as u128) / reduction).max(
        SCALE as u128,
    );
    let factor = (impulse as u128) * (SCALE as u128) / burden_ratio;
    (factor.min(MAX_FUEL_FACTOR as u128) as u64).max(MIN_FUEL_FACTOR)
}

public fun scale(): u64 {
    SCALE
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

public fun connected(grid: &PowerGrid): &VecMap<u64, u64> {
    &grid.connected
}

public fun is_connected(grid: &PowerGrid, module_id: u64): bool {
    grid.connected.contains(&module_id)
}

/// The priority group of a connected module.
public fun priority(grid: &PowerGrid, module_id: u64): u64 {
    assert!(grid.connected.contains(&module_id), ENotConnected);
    grid.connected[&module_id]
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

// === Private Functions ===

/// Borrow the grid mid-interaction and pop the next requirement.
fun take<T: drop>(
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

/// Toggle a Generator and adjust `capacity_mw`.
fun set_generator_online(
    grid: &mut PowerGrid,
    entity_id: ID,
    generator_id: u64,
    online: bool,
    clock: &Clock,
) {
    assert!(grid.generators.contains(&generator_id), EGeneratorNotRegistered);
    // Settle before capacity changes: fuel burn depends on which Generators run.
    grid.settle(entity_id, clock);
    let state = grid.generators.get_mut(&generator_id);
    if (online) assert!(!state.online, EGeneratorAlreadyOnline)
    else assert!(state.online, EGeneratorAlreadyOffline);
    state.online = online;
    let output = state.max_output_mw;
    grid.capacity_mw = if (online) grid.capacity_mw + output else grid.capacity_mw - output;
    event::emit(GeneratorToggled { entity_id, generator_id, online });
    event::emit(CapacityChanged { entity_id, capacity_mw: grid.capacity_mw });
    grid.shed(entity_id);
}

/// Drop `module_id`'s reservation and free its draw and line loss.
fun release_module(grid: &mut PowerGrid, module_id: u64) {
    let state = &mut grid.modules[&module_id];
    let reservation = state.reservation.extract();
    grid.used_mw = grid.used_mw - (reservation.active_draw + state.line_loss);
}

/// Module ids with a reservation in priority group `priority`.
fun reserved_at(grid: &PowerGrid, priority: u64): vector<u64> {
    let mut module_ids = vector[];
    grid.modules.length().do!(|i| {
        let (module_id, state) = grid.modules.get_entry_by_idx(i);
        if (state.reservation.is_some() && grid.connected[module_id] == priority) {
            module_ids.push_back(*module_id);
        };
    });
    module_ids
}

/// Module ids that hold a reservation, in connect order.
fun reserved_modules(grid: &PowerGrid): vector<u64> {
    let mut module_ids = vector[];
    grid.modules.length().do!(|i| {
        let (module_id, state) = grid.modules.get_entry_by_idx(i);
        if (state.reservation.is_some()) module_ids.push_back(*module_id);
    });
    module_ids
}

/// Release reservations until usage fits. Usable power of 0 releases every
/// reservation in one pass. Otherwise whole priority groups go, highest
/// group number first. Group 0 is last.
fun shed(grid: &mut PowerGrid, entity_id: ID) {
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
            let (module_id, state) = grid.modules.get_entry_by_idx(i);
            let priority = grid.connected[module_id];
            if (state.reservation.is_some() && priority > highest) highest = priority;
        });
        grid.reserved_at(highest).do!(|module_id| {
            grid.release_module(module_id);
            event::emit(Shed { entity_id, module_id });
        });
    };
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

/// Abort if a Generator is short of a `GeneratorRequirement`.
fun enforce_generator(requirement: &Requirement, grid: &PowerGrid) {
    let mut encoded = bcs::new(requirement.data());
    let generator_id = encoded.peel_u64();
    let online = encoded.peel_bool();
    let max_output_mw = encoded.peel_option_u64();
    let containment_reduction = encoded.peel_option_u64();
    assert!(grid.generators.contains(&generator_id), EGeneratorNotRegistered);
    let state = grid.generators.get(&generator_id);
    assert!(state.online == online, EGenNotOnline);
    max_output_mw.do!(|min_output| assert!(state.max_output_mw >= min_output, EOutputBelowMin));
    containment_reduction.do!(|min_containment| {
        assert!(state.containment_reduction >= min_containment, EContainmentBelowMin)
    });
}

/// Abort if a module's reservation is short of a `ReserveRequirement`.
fun enforce_reserved(requirement: &Requirement, grid: &PowerGrid) {
    let mut encoded = bcs::new(requirement.data());
    let module_id = encoded.peel_u64();
    let draw = encoded.peel_u64();
    let firm = match (encoded.peel_enum_tag()) {
        0 => true,
        1 => false,
        _ => abort EUnknownDrawKind,
    };
    assert!(grid.has_reservation(module_id), ENotReserved);
    let reservation = grid.modules[&module_id].reservation.borrow();
    assert!(reservation.kind.is_firm() == firm, EDrawKindMismatch);
    assert!(reservation.active_draw >= draw, EDrawBelowMin);
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
    min_impulse.do!(|min| assert!(impulse >= min, EImpulseBelowMin));
    max_containment_burden.do!(|max| assert!(containment_burden <= max, EBurdenAboveMax));
    min_amount.do!(|min| assert!(amount >= min, EFuelAmountBelowMin));
    max_amount.do!(|max| assert!(amount <= max, EFuelAmountAboveMax));
}

/// Burn the fuel used since the last settle and advance to now. Running dry
/// zeroes effective capacity, so every reservation is shed.
fun settle(grid: &mut PowerGrid, entity_id: ID, clock: &Clock) {
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

/// Fuel burned between `last_settled_ms` and `now_ms`, capped at what is left.
/// Each online Generator serves load in proportion to its output and burns
/// `load / factor` units per second at its own containment. Rounds up, so
/// frequent settles never burn less than the true amount.
fun fuel_burn(grid: &PowerGrid, now_ms: u64): u64 {
    if (now_ms <= grid.last_settled_ms || grid.fuel_impulse == 0) return 0;
    let load = grid.used_mw.min(grid.capacity_mw) as u128;
    if (load == 0 || grid.settled_fuel_quantity == 0) return 0;
    let elapsed_ms = (now_ms - grid.last_settled_ms) as u128;
    let mut burn = 0u128;
    grid.generators.length().do!(|i| {
        let (_, state) = grid.generators.get_entry_by_idx(i);
        if (state.online) {
            let share = load * (state.max_output_mw as u128) / (grid.capacity_mw as u128);
            let factor = fuel_factor(
                grid.fuel_impulse,
                grid.fuel_containment_burden,
                state.containment_reduction,
            );
            burn =
                burn + divide_round_up(
                    share * (SCALE as u128) * elapsed_ms,
                    (factor as u128) * (MS_PER_SECOND as u128),
                );
        };
    });
    (burn.min(grid.settled_fuel_quantity as u128)) as u64
}

/// Quantity-weighted average of the pool's stat and the stat just added.
fun blend(pooled_stat: u64, pooled_quantity: u64, added_stat: u64, added_quantity: u64): u64 {
    let total =
        (pooled_stat as u128) * (pooled_quantity as u128)
            + (added_stat as u128) * (added_quantity as u128);
    (total / ((pooled_quantity + added_quantity) as u128)) as u64
}

fun divide_round_up(numerator: u128, denominator: u128): u128 {
    (numerator + denominator - 1) / denominator
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

fun operate_grid_permit(): Permit<OperateGrid> {
    internal::permit<OperateGrid>()
}

fun manage_generator_permit(): Permit<ManageGenerator> {
    internal::permit<ManageGenerator>()
}

fun generator_requirement_permit(): Permit<GeneratorRequirement> {
    internal::permit<GeneratorRequirement>()
}

fun manage_module_permit(): Permit<ManageModule> {
    internal::permit<ManageModule>()
}

fun reserve_permit(): Permit<ReserveRequirement> {
    internal::permit<ReserveRequirement>()
}

fun manage_fuel_permit(): Permit<ManageFuel> {
    internal::permit<ManageFuel>()
}

fun deposit_fuel_permit(): Permit<DepositFuel> {
    internal::permit<DepositFuel>()
}

// === Test Functions ===

/// `(entity_id, fuel_type, amount, resulting_quantity, resulting_impulse, resulting_containment_burden)`.
#[test_only]
public fun fuel_added_fields(e: &FuelAdded): (ID, u64, u64, u64, u64, u64) {
    (
        e.entity_id,
        e.fuel_type,
        e.amount,
        e.resulting_quantity,
        e.resulting_impulse,
        e.resulting_containment_burden,
    )
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

/// `(entity_id, module_id, line_loss, priority)`.
#[test_only]
public fun module_connected_fields(e: &ModuleConnected): (ID, u64, u64, u64) {
    (e.entity_id, e.module_id, e.line_loss, e.priority)
}

/// `(entity_id, module_id, priority)`.
#[test_only]
public fun priority_changed_fields(e: &PriorityChanged): (ID, u64, u64) {
    (e.entity_id, e.module_id, e.priority)
}

/// `(entity_id, module_id, kind, requested, line_loss, active_draw)`.
#[test_only]
public fun reserved_fields(e: &Reserved): (ID, u64, DrawKind, u64, u64, u64) {
    (e.entity_id, e.module_id, e.kind, e.requested, e.line_loss, e.active_draw)
}

/// `(entity_id, module_id)`.
#[test_only]
public fun shed_fields(e: &Shed): (ID, u64) {
    (e.entity_id, e.module_id)
}

/// `(entity_id, module_id)`.
#[test_only]
public fun released_fields(e: &Released): (ID, u64) {
    (e.entity_id, e.module_id)
}
