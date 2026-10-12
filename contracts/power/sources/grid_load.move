/// Module connect, disconnect, priority and desired state. A module connects to
/// the grid inside its own install and disconnects inside its own uninstall.
/// The owner sets desired state, and `power_grid` derives
/// the grant. Only the module's own package can call `connect` or `disconnect`, since
/// both take its `Permit<Module>`.
module power::grid_load;

use core::{access_cap, entity::Entity, request::Request, requirement::Requirement};
use power::power_grid::{Self, DrawKind, ModulePowerSpec, PowerGrid};
use std::internal::Permit;
use sui::{bcs, clock::Clock, event};

// === Errors ===

#[error(code = 0)]
const EModuleMissing: vector<u8> = b"Module component is not installed on this entity";
#[error(code = 1)]
const EModuleAlreadyConnected: vector<u8> = b"Module is already connected to this power grid";
#[error(code = 2)]
const ETooManyConnected: vector<u8> = b"Power grid has reached its maximum connected modules";
#[error(code = 3)]
const EZeroPowerReq: vector<u8> = b"Module power requirement must be greater than zero";
#[error(code = 4)]
const EOutOfFuel: vector<u8> = b"Power grid has run out of fuel";
#[error(code = 5)]
const EDrawBelowMin: vector<u8> = b"Module's granted draw is below the requirement";
#[error(code = 6)]
const EDrawKindMismatch: vector<u8> = b"Module's draw kind does not match the requirement";
#[error(code = 7)]
const ENoGrant: vector<u8> = b"Module has no power granted";

// === Events ===

public struct ModuleConnected has copy, drop {
    entity_id: ID,
    module_id: u64,
    line_loss: u64,
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

/// The owner set a module's desired state.
public struct DesiredStateChanged has copy, drop {
    entity_id: ID,
    module_id: u64,
    online: bool,
}

// === Public Functions ===

/// Connect the installed module of type `Module` to the grid with `module_spec`. Called
/// from the module's own install, after `entity.install`. The module starts
/// desired offline and drawing nothing. Aborts if the grid is not installed.
public fun connect<Module: store>(
    entity: &mut Entity,
    module_id: u64,
    module_spec: ModulePowerSpec,
    _: Permit<Module>,
    clock: &Clock,
) {
    assert!(entity.has_component_with_type<Module>(module_id), EModuleMissing);
    assert!(module_spec.spec_power_req() > 0, EZeroPowerReq);
    let entity_id = entity.id();
    let grid = power_grid::grid_mut(entity);
    assert!(!grid.is_module_connected(module_id), EModuleAlreadyConnected);
    assert!(grid.modules().length() < power_grid::max_connected(), ETooManyConnected);
    grid.settle(entity_id, clock);
    let line_loss = module_spec.spec_line_loss();
    let priority = module_spec.spec_priority();
    grid.connect_module(module_id, module_spec);
    event::emit(ModuleConnected { entity_id, module_id, line_loss, priority });
}

/// Disconnect a module from the grid, releasing its grant. Called from the module's
/// own uninstall, after `entity.uninstall`. The other modules regrant.
public fun disconnect<Module: store>(
    entity: &mut Entity,
    module_id: u64,
    _: Permit<Module>,
    clock: &Clock,
) {
    let entity_id = entity.id();
    let grid = power_grid::grid_mut(entity);
    grid.assert_module_connected(module_id);
    grid.settle(entity_id, clock);
    grid.disconnect_module(module_id);
    grid.regrant(entity_id);
    event::emit(ModuleDisconnected { entity_id, module_id });
}

/// Move a connected module into priority group `priority`. Grants ignore it in v1.
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
    grid.assert_module_connected(module_id);
    grid.settle(entity_id, clock);
    grid.set_module_priority(module_id, priority);
    event::emit(PriorityChanged { entity_id, module_id, priority });
    frame.require(access_cap::owner_requirement());
    req.enqueue(frame);
}

/// Set a connected module's desired state. Always accepted, even without power.
/// The grid regrants, and the module draws only if the grid can carry it.
public fun set_desired_state(
    entity: &mut Entity,
    req: &mut Request,
    module_id: u64,
    online: bool,
    clock: &Clock,
) {
    let entity_id = entity.id();
    let (_requirement, mut frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::operate_grid_permit(),
    );
    grid.assert_module_connected(module_id);
    grid.settle(entity_id, clock);
    grid.set_module_desired_online(module_id, online);
    grid.regrant(entity_id);
    event::emit(DesiredStateChanged { entity_id, module_id, online });
    frame.require(access_cap::owner_requirement());
    req.enqueue(frame);
}

/// Abort unless the module in the next `OnlineRequirement` holds a grant of the
/// required draw kind and size. Settles first, so a grid that ran out of fuel since
/// the last touch fails here.
public fun assert_online(entity: &mut Entity, req: &mut Request, clock: &Clock) {
    let entity_id = entity.id();
    let (requirement, frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::online_permit(),
    );
    grid.settle(entity_id, clock);
    assert!(grid.fuel_quantity_at_last_settled() > 0, EOutOfFuel);
    enforce_online(&requirement, grid);
    frame.destroy_empty_frame();
}

// === Private Functions ===

/// Abort if a module's grant is short of an `OnlineRequirement`.
fun enforce_online(requirement: &Requirement, grid: &PowerGrid) {
    let mut encoded = bcs::new(requirement.data());
    let module_id = encoded.peel_u64();
    let draw = encoded.peel_u64();
    let draw_kind: DrawKind = power_grid::draw_kind_from_tag(encoded.peel_enum_tag());
    grid.assert_module_connected(module_id);
    let state = grid.module_state(module_id);
    let granted = state.active_draw_at_last_settled();
    assert!(granted > 0, ENoGrant);
    assert!(state.draw_kind() == draw_kind, EDrawKindMismatch);
    assert!(granted >= draw, EDrawBelowMin);
}

// === Test Functions ===

/// `(entity_id, module_id, line_loss, priority)`.
#[test_only]
public fun module_connected_fields(connected: &ModuleConnected): (ID, u64, u64, u64) {
    (connected.entity_id, connected.module_id, connected.line_loss, connected.priority)
}

/// `(entity_id, module_id)`.
#[test_only]
public fun module_disconnected_fields(disconnected: &ModuleDisconnected): (ID, u64) {
    (disconnected.entity_id, disconnected.module_id)
}

/// `(entity_id, module_id, priority)`.
#[test_only]
public fun priority_changed_fields(changed: &PriorityChanged): (ID, u64, u64) {
    (changed.entity_id, changed.module_id, changed.priority)
}

/// `(entity_id, module_id, online)`.
#[test_only]
public fun desired_state_changed_fields(changed: &DesiredStateChanged): (ID, u64, bool) {
    (changed.entity_id, changed.module_id, changed.online)
}
