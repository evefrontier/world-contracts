#[test_only]
module power::power_grid_tests;

use core::{
    access_cap::{Self, AccessCap},
    action,
    admin_service::{Self, AdminACL},
    component,
    entity::{Self, Entity},
    object_registry::ObjectRegistry,
    requirement::Requirement,
    test_helpers::{claim, setup, take_acl, take_registry}
};
use power::{grid_scenario, power_grid::{Self, PowerGridInstalled, PowerToggled}};
use std::string;
use sui::{clock::{Self, Clock}, event, test_scenario as ts};

const ADMIN: address = @0xA;
const OWNER: address = @0xB;
const OPERATE: vector<u8> = b"operate_grid";
const CHECK_GRID: vector<u8> = b"check_grid";

/// Install a grid on a fresh entity. No access caps yet.
fun build_entity(
    scenario: &mut ts::Scenario,
    registry: &mut ObjectRegistry,
    acl: &AdminACL,
    clock: &Clock,
): Entity {
    let mut e = claim(registry, acl, 1, scenario.ctx());
    let mut req = power_grid::install(&mut e, clock, scenario.ctx());
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);
    e
}

/// Share an entity with a grid, mint its AccessCap to OWNER and enable the
/// owner-gated `operate_grid` action. Returns the entity id.
fun setup_grid(scenario: &mut ts::Scenario, clock: &Clock): ID {
    ts::next_tx(scenario, ADMIN);
    let mut registry = take_registry(scenario);
    let acl = take_acl(scenario);
    let mut e = build_entity(scenario, &mut registry, &acl, clock);
    let entity_id = e.id();
    let mut req = e.mint_access(OWNER, false, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);

    ts::next_tx(scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    enable(scenario, &mut e, &cap, OPERATE, power_grid::operate_grid_requirement());
    ts::return_to_sender(scenario, cap);
    ts::return_shared(e);
    entity_id
}

fun enable(
    scenario: &mut ts::Scenario,
    e: &mut Entity,
    cap: &AccessCap,
    name: vector<u8>,
    grid_requirement: Requirement,
) {
    let act = action::new(vector[access_cap::owner_requirement(), grid_requirement]);
    let mut req = e.enable_action(string::utf8(name), act, scenario.ctx());
    access_cap::verify(&mut req, cap);
    e.complete_request(req);
}

/// Owner enables `check_grid` with `rule`, then runs it.
fun run_grid_check(scenario: &mut ts::Scenario, entity_id: ID, rule: Requirement, clock: &Clock) {
    ts::next_tx(scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    enable(scenario, &mut e, &cap, CHECK_GRID, rule);
    ts::return_to_sender(scenario, cap);
    ts::return_shared(e);

    ts::next_tx(scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let mut req = e.interact(string::utf8(CHECK_GRID), scenario.ctx());
    access_cap::verify(&mut req, &cap);
    power_grid::assert_power_grid(&mut e, &mut req, clock);
    e.complete_request(req);
    ts::return_to_sender(scenario, cap);
    ts::return_shared(e);
}

/// Owner runs `set_power_grid`, passing `on`.
fun toggle(scenario: &mut ts::Scenario, entity_id: ID, on: bool, clock: &Clock) {
    ts::next_tx(scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let mut req = e.interact(string::utf8(OPERATE), scenario.ctx());
    access_cap::verify(&mut req, &cap);
    power_grid::set_power_grid(&mut e, &mut req, on, clock);
    e.complete_request(req);
    ts::return_to_sender(scenario, cap);
    ts::return_shared(e);
}

#[test]
fun install_starts_off_and_empty() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_entity(&mut scenario, &mut registry, &acl, &clock);

    assert!(power_grid::component_id() == component::id_from_name(b"power_grid"));
    let grid = power_grid::power_grid(&e);
    assert!(!grid.on());
    assert!(grid.capacity_mw() == 0);
    assert!(grid.used_mw() == 0);
    assert!(grid.fuel_capacity() == 0);
    assert!(grid.settled_fuel_quantity() == 0);
    assert!(grid.fuel_impulse() == 0);
    assert!(grid.fuel_containment_burden() == 0);
    assert!(grid.last_settled_ms() == 1_000);
    assert!(grid.connected().is_empty());
    assert!(grid.generators().is_empty());
    assert!(grid.fuel_sources().is_empty());
    assert!(grid.modules().is_empty());
    assert!(grid.effective_capacity_mw() == 0);

    let installed = event::events_by_type<PowerGridInstalled>();
    assert!(installed.length() == 1);
    let (entity_id, component_id) = installed[0].installed_fields();
    assert!(entity_id == e.id());
    assert!(component_id == power_grid::component_id());

    e.share();
    clock.destroy_for_testing();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = entity::EComponentExists)]
fun install_twice_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = build_entity(&mut scenario, &mut registry, &acl, &clock);
    let _req = power_grid::install(&mut e, &clock, scenario.ctx());

    abort
}

#[test]
fun power_on_then_off() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_grid(&mut scenario, &clock);

    clock.set_for_testing(2_000);
    toggle(&mut scenario, entity_id, true, &clock);
    ts::next_tx(&mut scenario, OWNER);
    {
        let e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
        let grid = power_grid::power_grid(&e);
        assert!(grid.on());
        assert!(grid.last_settled_ms() == 2_000);
        ts::return_shared(e);
    };

    clock.set_for_testing(3_000);
    toggle(&mut scenario, entity_id, false, &clock);
    let toggled = event::events_by_type<PowerToggled>();
    assert!(toggled.length() == 1);
    let (event_entity, on) = toggled[0].toggled_fields();
    assert!(event_entity == entity_id);
    assert!(!on);

    ts::next_tx(&mut scenario, OWNER);
    {
        let e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
        let grid = power_grid::power_grid(&e);
        assert!(!grid.on());
        assert!(grid.last_settled_ms() == 3_000);
        ts::return_shared(e);
    };

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = power_grid::EAlreadyOn)]
fun power_on_twice_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_grid(&mut scenario, &clock);

    toggle(&mut scenario, entity_id, true, &clock);
    toggle(&mut scenario, entity_id, true, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::EAlreadyOff)]
fun power_off_while_off_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_grid(&mut scenario, &clock);

    toggle(&mut scenario, entity_id, false, &clock);

    abort
}

#[test, expected_failure(abort_code = access_cap::ENotOwner)]
fun power_on_with_other_entity_cap_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_grid(&mut scenario, &clock);

    // OWNER also holds the cap of a second entity; it must not open the first.
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut other = claim(&mut registry, &acl, 2, scenario.ctx());
    let mut req = other.mint_access(OWNER, false, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    other.complete_request(req);
    let other_cap_owner_id = other.id();
    other.share();
    ts::return_shared(acl);
    ts::return_shared(registry);

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    let other_cap = ts::take_from_sender<AccessCap>(&scenario);
    assert!(other_cap.entity() == other_cap_owner_id);
    let mut req = e.interact(string::utf8(OPERATE), scenario.ctx());
    access_cap::verify(&mut req, &other_cap);

    abort
}

#[test]
fun uninstall_removes_grid() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = build_entity(&mut scenario, &mut registry, &acl, &clock);

    let mut req = power_grid::uninstall(&mut e, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    assert!(!e.has_component(power_grid::component_id()));

    e.share();
    clock.destroy_for_testing();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = power_grid::EComponentMissing)]
fun uninstall_without_grid_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let _req = power_grid::uninstall(&mut e, scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = power_grid::EComponentMissing)]
fun view_without_grid_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = claim(&mut registry, &acl, 1, scenario.ctx());
    power_grid::power_grid(&e);

    abort
}

#[test]
fun grid_check_passes_for_off_empty_grid() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_grid(&mut scenario, &clock);

    run_grid_check(
        &mut scenario,
        entity_id,
        power_grid::power_grid_requirement(
            false,
            option::some(0),
            option::some(0),
            0,
            option::some(0),
        ),
        &clock,
    );

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun grid_check_passes_when_on() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_grid(&mut scenario, &clock);
    toggle(&mut scenario, entity_id, true, &clock);

    run_grid_check(
        &mut scenario,
        entity_id,
        power_grid::power_grid_requirement(true, option::none(), option::none(), 0, option::none()),
        &clock,
    );

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = power_grid::EGridState)]
fun grid_check_aborts_when_on_required() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_grid(&mut scenario, &clock);

    run_grid_check(
        &mut scenario,
        entity_id,
        power_grid::power_grid_requirement(true, option::none(), option::none(), 0, option::none()),
        &clock,
    );

    abort
}

#[test, expected_failure(abort_code = power_grid::EFuelBelowMin)]
fun grid_check_aborts_when_fuel_below() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_grid(&mut scenario, &clock);

    run_grid_check(
        &mut scenario,
        entity_id,
        power_grid::power_grid_requirement(
            false,
            option::some(1),
            option::none(),
            0,
            option::none(),
        ),
        &clock,
    );

    abort
}

#[test, expected_failure(abort_code = power_grid::EImpulseBelowMin)]
fun grid_check_aborts_when_impulse_below() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_grid(&mut scenario, &clock);

    run_grid_check(
        &mut scenario,
        entity_id,
        power_grid::power_grid_requirement(
            false,
            option::none(),
            option::some(1),
            0,
            option::none(),
        ),
        &clock,
    );

    abort
}

#[test, expected_failure(abort_code = power_grid::ECapacityBelowMin)]
fun grid_check_aborts_when_capacity_below() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_grid(&mut scenario, &clock);

    run_grid_check(
        &mut scenario,
        entity_id,
        power_grid::power_grid_requirement(
            false,
            option::none(),
            option::none(),
            1,
            option::none(),
        ),
        &clock,
    );

    abort
}

#[test, expected_failure(abort_code = power_grid::EUsedAboveMax)]
fun grid_check_aborts_when_used_above() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = grid_scenario::setup_entity(&mut scenario, vector[50], vector[201], &clock);
    grid_scenario::power_up(&mut scenario, entity_id, 1, &clock);
    grid_scenario::connect(&mut scenario, entity_id, 201, 0, 0, &clock);
    grid_scenario::reserve_firm(&mut scenario, entity_id, 201, 1, &clock);

    run_grid_check(
        &mut scenario,
        entity_id,
        power_grid::power_grid_requirement(
            true,
            option::none(),
            option::none(),
            0,
            option::some(0),
        ),
        &clock,
    );

    abort
}
