/// Generator register and on/off. Borrows the grid and asks `power_grid` to
/// write capacity. Does not touch grid fields.
module power::grid_generator;

use core::{access_cap, admin_service, entity::Entity, request::Request, requirement::Requirement};
use power::{generator, power_grid};
use sui::{bcs, clock::Clock, event};

// === Errors ===

#[error(code = 0)]
const EZeroBaseFuelRate: vector<u8> = b"Generator base fuel rate must be greater than zero";
#[error(code = 1)]
const EGeneratorAlreadyRegistered: vector<u8> =
    b"Generator is already registered with this power grid";
#[error(code = 2)]
const EGeneratorNotRegistered: vector<u8> = b"Generator is not registered with this power grid";
#[error(code = 3)]
const EGeneratorOnline: vector<u8> = b"Generator must be offline to be removed from the grid";
#[error(code = 4)]
const EGeneratorAlreadyOnline: vector<u8> = b"Generator is already online";
#[error(code = 5)]
const EGeneratorAlreadyOffline: vector<u8> = b"Generator is already offline";
#[error(code = 6)]
const EGeneratorStillRegistered: vector<u8> =
    b"Generator must be unregistered from the power grid before uninstall";
#[error(code = 7)]
const EGenNotOnline: vector<u8> = b"Generator's online state does not match the requirement";
#[error(code = 8)]
const EOutputBelowMin: vector<u8> = b"Generator output is below the requirement";
#[error(code = 9)]
const EContainmentBelowMin: vector<u8> = b"Containment reduction is below the requirement";

// === Events ===

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
    base_fuel_rate: u64,
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

/// Register an installed Generator with its stats, offline. Admin-only.
public fun register_generator(
    entity: &mut Entity,
    req: &mut Request,
    generator_id: u64,
    max_output_mw: u64,
    containment_reduction: u64,
    base_fuel_rate: u64,
    clock: &Clock,
) {
    assert!(base_fuel_rate > 0, EZeroBaseFuelRate);
    generator::assert_installed(entity, generator_id);
    let entity_id = entity.id();
    let (_requirement, mut frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::manage_generator_permit(),
    );
    assert!(!power_grid::generators(grid).contains(&generator_id), EGeneratorAlreadyRegistered);
    power_grid::settle(grid, entity_id, clock);
    power_grid::insert_generator(
        grid,
        generator_id,
        max_output_mw,
        containment_reduction,
        base_fuel_rate,
    );
    event::emit(GeneratorRegistered {
        entity_id,
        generator_id,
        max_output_mw,
        containment_reduction,
        base_fuel_rate,
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
    let (_requirement, mut frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::manage_generator_permit(),
    );
    assert!(power_grid::generators(grid).contains(&generator_id), EGeneratorNotRegistered);
    // TODO: we can automatically offline and unregister if needed
    assert!(!power_grid::generators(grid).get(&generator_id).online(), EGeneratorOnline);
    power_grid::settle(grid, entity_id, clock);
    power_grid::remove_generator(grid, generator_id);
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
    assert!(!power_grid::is_generator_registered(entity, generator_id), EGeneratorStillRegistered);
    generator::uninstall(entity, generator_id, ctx)
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
    assert!(power_grid::generators(grid).contains(&generator_id), EGeneratorNotRegistered);
    power_grid::settle(grid, entity_id, clock);
    let already_online = power_grid::generators(grid).get(&generator_id).online();
    if (online) assert!(!already_online, EGeneratorAlreadyOnline)
    else assert!(already_online, EGeneratorAlreadyOffline);
    power_grid::apply_generator_online(grid, generator_id, online);
    event::emit(GeneratorToggled { entity_id, generator_id, online });
    event::emit(CapacityChanged { entity_id, capacity_mw: power_grid::capacity_mw(grid) });
    power_grid::shed(grid, entity_id);
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
    assert!(power_grid::generators(grid).contains(&generator_id), EGeneratorNotRegistered);
    let state = power_grid::generators(grid).get(&generator_id);
    assert!(state.online() == online, EGenNotOnline);
    max_output_mw.do!(|min_output| {
        assert!(state.max_output_mw() >= min_output, EOutputBelowMin)
    });
    containment_reduction.do!(|min_containment| {
        assert!(state.containment_reduction() >= min_containment, EContainmentBelowMin)
    });
}
