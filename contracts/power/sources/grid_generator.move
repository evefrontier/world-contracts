/// Generator install, uninstall and on/off. Installing the component connects it
/// to the grid. Borrows the grid and asks `power_grid` to write capacity.
module power::grid_generator;

use core::{access_cap, entity::Entity, request::Request, requirement::Requirement};
use power::{generator, power_grid};
use std::string::String;
use sui::{bcs, clock::Clock, event};

// === Errors ===

#[error(code = 0)]
const EZeroBaseFuelRate: vector<u8> = b"Generator base fuel rate must be greater than zero";
#[error(code = 1)]
const EGeneratorNotConnected: vector<u8> = b"Generator is not connected to this power grid";
#[error(code = 2)]
const EGeneratorAlreadyOnline: vector<u8> = b"Generator is already online";
#[error(code = 3)]
const EGeneratorAlreadyOffline: vector<u8> = b"Generator is already offline";
#[error(code = 4)]
const EGeneratorNotOnline: vector<u8> = b"Generator's online state does not match the requirement";
#[error(code = 5)]
const EOutputBelowMin: vector<u8> = b"Generator output is below the requirement";
#[error(code = 6)]
const EContainmentBelowMin: vector<u8> = b"Containment reduction is below the requirement";
#[error(code = 7)]
const EWrongTenant: vector<u8> = b"Generators can only move between entities of the same tenant";

// === Events ===

/// The grid's `capacity_mw` changed.
public struct CapacityChanged has copy, drop {
    entity_id: ID,
    capacity_mw: u64,
}

public struct GeneratorConnected has copy, drop {
    entity_id: ID,
    generator_id: u64,
    max_output_mw: u64,
    containment_reduction: u64,
    base_fuel_rate: u64,
}

public struct GeneratorDisconnected has copy, drop {
    entity_id: ID,
    generator_id: u64,
}

public struct GeneratorToggled has copy, drop {
    entity_id: ID,
    generator_id: u64,
    online: bool,
}

// === Public Functions ===

/// Install a Generator and add it to the grid, offline. Admin-gated.
public fun install(
    entity: &mut Entity,
    component_id: u64,
    name: Option<String>,
    max_output_mw: u64,
    containment_reduction: u64,
    base_fuel_rate: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    assert!(base_fuel_rate > 0, EZeroBaseFuelRate);
    let entity_id = entity.id();
    let req = generator::install(entity, component_id, name, ctx);
    let grid = power_grid::grid_mut(entity);
    grid.settle(clock);
    grid.connect_generator(component_id, max_output_mw, containment_reduction, base_fuel_rate);
    grid.regrant(entity_id);
    event::emit(GeneratorConnected {
        entity_id,
        generator_id: component_id,
        max_output_mw,
        containment_reduction,
        base_fuel_rate,
    });
    req
}

/// Uninstall a Generator and remove it from the grid. Settles first, so burn
/// still includes it, then drops its output from capacity if it was online.
/// Admin-gated.
public fun uninstall(
    entity: &mut Entity,
    generator_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    assert!(power_grid::is_generator_connected(entity, generator_id), EGeneratorNotConnected);
    let was_online = power_grid::generator_state(entity, generator_id).online();
    let entity_id = entity.id();
    let req = generator::uninstall(entity, generator_id, ctx);
    let grid = power_grid::grid_mut(entity);
    grid.settle(clock);
    grid.disconnect_generator(generator_id);
    if (was_online) {
        event::emit(CapacityChanged { entity_id, capacity_mw: power_grid::capacity_mw(grid) });
    };
    grid.regrant(entity_id);
    event::emit(GeneratorDisconnected { entity_id, generator_id });
    req
}

/// Move Generator `generator_id` from `from` to `to`, keeping its stats and
/// online state, so its output leaves `from`'s capacity and joins `to`'s.
/// Admin-gated: returns `from`'s request, then `to`'s.
public fun migrate(
    from: &mut Entity,
    to: &mut Entity,
    generator_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Request, Request) {
    assert!(from.key().tenant() == to.key().tenant(), EWrongTenant);
    assert!(power_grid::is_generator_connected(from, generator_id), EGeneratorNotConnected);
    let state = power_grid::generator_state(from, generator_id);
    let name = generator::name(from, generator_id);
    let from_req = uninstall(from, generator_id, clock, ctx);
    let to_req = install(
        to,
        generator_id,
        name,
        state.max_output_mw(),
        state.containment_reduction(),
        state.base_fuel_rate(),
        clock,
        ctx,
    );
    if (state.online()) {
        let entity_id = to.id();
        let grid = power_grid::grid_mut(to);
        grid.set_generator_online(generator_id, true);
        grid.regrant(entity_id);
        event::emit(GeneratorToggled { entity_id, generator_id, online: true });
        event::emit(CapacityChanged { entity_id, capacity_mw: power_grid::capacity_mw(grid) });
    };
    (from_req, to_req)
}

/// Bring a Generator online or offline. Settles before capacity changes,
/// because burn depends on which Generators run.
public fun set_generator(
    entity: &mut Entity,
    req: &mut Request,
    generator_id: u64,
    online: bool,
    clock: &Clock,
) {
    let entity_id = entity.id();
    let (_requirement, mut frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::operate_grid_permit(),
    );
    assert!(power_grid::generators(grid).contains(&generator_id), EGeneratorNotConnected);
    grid.settle(clock);
    let already_online = power_grid::generators(grid).get(&generator_id).online();
    if (online) assert!(!already_online, EGeneratorAlreadyOnline)
    else assert!(already_online, EGeneratorAlreadyOffline);
    grid.set_generator_online(generator_id, online);
    event::emit(GeneratorToggled { entity_id, generator_id, online });
    event::emit(CapacityChanged { entity_id, capacity_mw: power_grid::capacity_mw(grid) });
    grid.regrant(entity_id);
    frame.require(access_cap::owner_requirement());
    req.enqueue(frame);
}

/// Abort unless a Generator meets the next `GeneratorRequirement`.
public fun assert_generator(entity: &mut Entity, req: &mut Request) {
    let (requirement, frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::generator_requirement_permit(),
    );
    enforce_generator(&requirement, grid);
    frame.destroy_empty_frame();
}

// === Private Functions ===

/// Abort if a Generator is short of a `GeneratorRequirement`.
fun enforce_generator(requirement: &Requirement, grid: &power_grid::PowerGrid) {
    let mut encoded = bcs::new(requirement.data());
    let generator_id = encoded.peel_u64();
    let online = encoded.peel_bool();
    let max_output_mw = encoded.peel_option_u64();
    let containment_reduction = encoded.peel_option_u64();
    assert!(power_grid::generators(grid).contains(&generator_id), EGeneratorNotConnected);
    let state = power_grid::generators(grid).get(&generator_id);
    assert!(state.online() == online, EGeneratorNotOnline);
    max_output_mw.do!(|min_output| {
        assert!(state.max_output_mw() >= min_output, EOutputBelowMin)
    });
    containment_reduction.do!(|min_containment| {
        assert!(state.containment_reduction() >= min_containment, EContainmentBelowMin)
    });
}

// === Test Functions ===

/// `(entity_id, capacity_mw)`.
#[test_only]
public fun capacity_changed_fields(capacity_changed: &CapacityChanged): (ID, u64) {
    (capacity_changed.entity_id, capacity_changed.capacity_mw)
}

/// `(entity_id, generator_id, max_output_mw, containment_reduction, base_fuel_rate)`.
#[test_only]
public fun generator_connected_fields(
    generator_connected: &GeneratorConnected,
): (ID, u64, u64, u64, u64) {
    (
        generator_connected.entity_id,
        generator_connected.generator_id,
        generator_connected.max_output_mw,
        generator_connected.containment_reduction,
        generator_connected.base_fuel_rate,
    )
}

/// `(entity_id, generator_id)`.
#[test_only]
public fun generator_disconnected_fields(
    generator_disconnected: &GeneratorDisconnected,
): (ID, u64) {
    (generator_disconnected.entity_id, generator_disconnected.generator_id)
}

/// `(entity_id, generator_id, online)`.
#[test_only]
public fun generator_toggled_fields(generator_toggled: &GeneratorToggled): (ID, u64, bool) {
    (generator_toggled.entity_id, generator_toggled.generator_id, generator_toggled.online)
}
