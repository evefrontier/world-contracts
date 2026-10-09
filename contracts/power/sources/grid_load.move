/// Connect, priority, reserve and release. Borrows the grid and asks
/// `power_grid` to write usage. Shed itself stays in `power_grid`, because
/// settle calls it and the two modules cannot import each other.
module power::grid_load;

use core::{access_cap, admin_service, entity::Entity, request::Request, requirement::Requirement};
use power::power_grid::{Self, DrawKind, PowerGrid};
use sui::{bcs, clock::Clock, event};

// === Errors ===

#[error(code = 0)]
const EModuleMissing: vector<u8> = b"Module component is not installed on this entity";
#[error(code = 1)]
const EModuleAlreadyRegistered: vector<u8> = b"Module is already registered with this power grid";
#[error(code = 2)]
const ETooManyConnected: vector<u8> = b"Power grid has reached its maximum connected modules";
#[error(code = 3)]
const EAlreadyReserved: vector<u8> = b"Module already has a power reservation";
#[error(code = 4)]
const ENotReserved: vector<u8> = b"Module has no power reservation";
#[error(code = 5)]
const EZeroDraw: vector<u8> = b"Power draw must be greater than zero";
#[error(code = 6)]
const EUnknownDrawKind: vector<u8> = b"Unknown draw kind";
#[error(code = 7)]
const EInsufficientPower: vector<u8> = b"Power grid does not have enough capacity for this draw";
#[error(code = 8)]
const EDrawBelowMin: vector<u8> = b"Module's active_draw draw is below the requirement";
#[error(code = 9)]
const EDrawKindMismatch: vector<u8> = b"Module's draw kind does not match the requirement";
#[error(code = 10)]
const EModuleStillConnected: vector<u8> =
    b"Module must be disconnected from the power grid before uninstall";
#[error(code = 11)]
const EOutOfFuel: vector<u8> = b"Power grid has run out of fuel";

// === Events ===

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

// === Public Functions ===

/// Connect an installed module of type `Module` to the grid in priority group 0,
/// with its line loss. Admin-only.
public fun connect_module<Module: store>(
    entity: &mut Entity,
    req: &mut Request,
    module_id: u64,
    line_loss: u64,
    clock: &Clock,
) {
    assert!(entity.has_component_with_type<Module>(module_id), EModuleMissing);
    let entity_id = entity.id();
    let (_requirement, mut frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::manage_module_permit(),
    );
    assert!(!power_grid::is_module_registered(grid, module_id), EModuleAlreadyRegistered);
    assert!(power_grid::modules(grid).length() < power_grid::max_connected(), ETooManyConnected);
    power_grid::settle(grid, entity_id, clock);
    power_grid::insert_module(grid, module_id, line_loss);
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
    let (_requirement, mut frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::manage_module_permit(),
    );
    power_grid::assert_module_registered(grid, module_id);
    power_grid::settle(grid, entity_id, clock);
    if (power_grid::has_reservation(grid, module_id)) {
        power_grid::release_module(grid, module_id);
        event::emit(Released { entity_id, module_id });
    };
    power_grid::remove_module(grid, module_id);
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
    let (_requirement, mut frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::operate_grid_permit(),
    );
    power_grid::assert_connected(grid, module_id);
    power_grid::settle(grid, entity_id, clock);
    power_grid::set_module_priority(grid, module_id, priority);
    event::emit(PriorityChanged { entity_id, module_id, priority });
    frame.require(access_cap::owner_requirement());
    req.enqueue(frame);
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
    assert!(entity.has_component(module_id), EModuleMissing);
    let (_requirement, mut frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::operate_grid_permit(),
    );
    assert!(draw > 0, EZeroDraw);
    power_grid::assert_connected(grid, module_id);
    // TODO: may later replace the existing reservation instead of aborting.
    assert!(!power_grid::has_reservation(grid, module_id), EAlreadyReserved);
    power_grid::settle(grid, entity_id, clock);
    let line_loss = power_grid::module_state(grid, module_id).line_loss();
    let effective = power_grid::effective_capacity_mw(grid);
    let used_mw = power_grid::used_mw(grid);
    let leftover = if (effective > used_mw) effective - used_mw else 0;
    assert!(leftover > line_loss, EInsufficientPower);
    let active_draw = if (kind.is_firm()) draw else draw.min(leftover - line_loss);
    assert!(active_draw + line_loss <= leftover, EInsufficientPower);
    power_grid::grant_reservation(grid, module_id, draw, active_draw, kind);
    event::emit(Reserved {
        entity_id,
        module_id,
        kind,
        requested: draw,
        line_loss,
        active_draw,
    });
    frame.require(access_cap::owner_requirement());
    req.enqueue(frame);
}

/// Release `module_id`'s reservation. Settles first. If that settle runs the
/// tank dry it already shed the reservation, and releasing again would abort.
public fun release(entity: &mut Entity, req: &mut Request, module_id: u64, clock: &Clock) {
    let entity_id = entity.id();
    let (_requirement, mut frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::operate_grid_permit(),
    );
    assert!(power_grid::has_reservation(grid, module_id), ENotReserved);
    power_grid::settle(grid, entity_id, clock);
    if (power_grid::has_reservation(grid, module_id)) {
        power_grid::release_module(grid, module_id);
        event::emit(Released { entity_id, module_id });
    };
    frame.require(access_cap::owner_requirement());
    req.enqueue(frame);
}

/// Release every reservation in priority group `priority`.
public fun release_priority(entity: &mut Entity, req: &mut Request, priority: u64, clock: &Clock) {
    let entity_id = entity.id();
    let (_requirement, mut frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::operate_grid_permit(),
    );
    power_grid::settle(grid, entity_id, clock);
    power_grid::reserved_at(grid, priority).do!(|module_id| {
        power_grid::release_module(grid, module_id);
        event::emit(Released { entity_id, module_id });
    });
    frame.require(access_cap::owner_requirement());
    req.enqueue(frame);
}

/// Abort unless the module in the next `ReserveRequirement` still holds a
/// matching reservation. Settles first, so a grid that ran out of fuel since
/// the last touch fails here instead of passing on stale state.
public fun assert_reserved(entity: &mut Entity, req: &mut Request, clock: &Clock) {
    let entity_id = entity.id();
    let (requirement, frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::reserve_permit(),
    );
    power_grid::settle(grid, entity_id, clock);
    assert!(power_grid::settled_fuel_quantity(grid) > 0, EOutOfFuel);
    enforce_reserved(&requirement, grid);
    frame.destroy_empty_frame();
}

/// Abort unless `module_id` is disconnected from the grid. A module's own package
/// calls this before it uninstalls the module's component, since a connected
/// module keeps its reservation.
public fun assert_disconnected(entity: &Entity, module_id: u64) {
    if (!entity.has_component_with_type<PowerGrid>(power_grid::component_id())) return;
    assert!(
        !power_grid::is_connected(power_grid::power_grid(entity), module_id),
        EModuleStillConnected,
    );
}

// === Private Functions ===

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
    assert!(power_grid::has_reservation(grid, module_id), ENotReserved);
    let reservation = power_grid::module_state(grid, module_id).reservation().destroy_some();
    assert!(reservation.kind().is_firm() == firm, EDrawKindMismatch);
    assert!(reservation.active_draw() >= draw, EDrawBelowMin);
}

// === Test Functions ===

/// `(entity_id, module_id, line_loss, priority)`.
#[test_only]
public fun module_connected_fields(connected: &ModuleConnected): (ID, u64, u64, u64) {
    (connected.entity_id, connected.module_id, connected.line_loss, connected.priority)
}

/// `(entity_id, module_id, priority)`.
#[test_only]
public fun priority_changed_fields(changed: &PriorityChanged): (ID, u64, u64) {
    (changed.entity_id, changed.module_id, changed.priority)
}

/// `(entity_id, module_id, kind, requested, line_loss, active_draw)`.
#[test_only]
public fun reserved_fields(reserved: &Reserved): (ID, u64, DrawKind, u64, u64, u64) {
    (
        reserved.entity_id,
        reserved.module_id,
        reserved.kind,
        reserved.requested,
        reserved.line_loss,
        reserved.active_draw,
    )
}

/// `(entity_id, module_id)`.
#[test_only]
public fun released_fields(released: &Released): (ID, u64) {
    (released.entity_id, released.module_id)
}
