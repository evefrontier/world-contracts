#[test_only]
module power::power_grid_tests;

use core::{admin_service, entity::Entity, test_helpers::{claim, setup, take_acl, take_registry}};
use power::{
    grid_scenario::{
        Self,
        admin,
        firm_power,
        install_module,
        power,
        setup_entity,
        starting_fuel,
        starting_units,
        temp_action,
        owner
    },
    power_grid
};
use sui::{clock::{Self, Clock}, test_scenario as ts};

const MOD_A: u64 = 401;
const OUTPUT: u64 = 15;
const CONTAINMENT: u64 = 10;
const DRAW: u64 = 10;
const IMPULSE: u64 = 90;

/// A grid with no power sources, off.
fun setup_grid(scenario: &mut ts::Scenario, clock: &Clock): ID {
    setup_entity(scenario, vector[], vector[], clock)
}

/// An entity with no power grid installed.
fun bare_entity(scenario: &mut ts::Scenario): ID {
    ts::next_tx(scenario, admin());
    let mut registry = take_registry(scenario);
    let acl = take_acl(scenario);
    let entity = claim(&mut registry, &acl, 3, scenario.ctx());
    let entity_id = entity.id();
    entity.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    entity_id
}

/// An entity with an installed grid and no power sources.
fun grid_only_entity(scenario: &mut ts::Scenario): ID {
    ts::next_tx(scenario, admin());
    let mut registry = take_registry(scenario);
    let acl = take_acl(scenario);
    let mut entity = claim(&mut registry, &acl, 4, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let mut req = power_grid::install(&mut entity, &clock, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    clock.destroy_for_testing();
    let entity_id = entity.id();
    entity.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    entity_id
}

/// Admin uninstalls the grid of `entity_id`.
fun uninstall_grid(scenario: &mut ts::Scenario, entity_id: ID) {
    ts::next_tx(scenario, admin());
    let mut entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let acl = take_acl(scenario);
    let mut req = power_grid::uninstall(&mut entity, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    ts::return_shared(acl);
    ts::return_shared(entity);
}

/// `(on, settled fuel in online bays, capacity_mw)` of the installed grid.
fun grid_flags(scenario: &mut ts::Scenario, entity_id: ID): (bool, u64, u64) {
    ts::next_tx(scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let grid = power_grid::power_grid(&entity);
    let on = grid.on();
    let fuel = grid.online_fuel().quantity();
    let capacity = grid.capacity_mw();
    ts::return_shared(entity);
    (on, fuel, capacity)
}

// === Install and uninstall ===

#[test]
fun install_starts_off_and_empty() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_grid(&mut scenario, &clock);

    let (on, fuel, capacity) = grid_flags(&mut scenario, entity_id);
    assert!(!on);
    assert!(fuel == starting_fuel());
    assert!(capacity == 0);

    clock.destroy_for_testing();
    scenario.end();
}

/// Claiming an entity leaves it with no grid. `power_grid::install` adds one, off and empty.
#[test]
fun install_grid_after_claim() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());

    ts::next_tx(&mut scenario, admin());
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut entity = claim(&mut registry, &acl, 5, scenario.ctx());
    assert!(!entity.has_component(power_grid::component_id()));
    let mut req = power_grid::install(&mut entity, &clock, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    assert!(entity.has_component(power_grid::component_id()));
    assert!(!power_grid::power_grid(&entity).on());
    entity.share();
    ts::return_shared(acl);
    ts::return_shared(registry);

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun power_on_then_off() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_grid(&mut scenario, &clock);

    power(&mut scenario, entity_id, true, &clock);
    let (on, _, _) = grid_flags(&mut scenario, entity_id);
    assert!(on);
    power(&mut scenario, entity_id, false, &clock);
    let (on, _, _) = grid_flags(&mut scenario, entity_id);
    assert!(!on);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = power_grid::EAlreadyOn)]
fun power_on_twice_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_grid(&mut scenario, &clock);
    power(&mut scenario, entity_id, true, &clock);
    power(&mut scenario, entity_id, true, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::EAlreadyOff)]
fun power_off_while_off_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_grid(&mut scenario, &clock);
    power(&mut scenario, entity_id, false, &clock);

    abort
}

#[test]
fun uninstall_removes_empty_grid() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = grid_only_entity(&mut scenario);
    uninstall_grid(&mut scenario, entity_id);

    ts::next_tx(&mut scenario, admin());
    let entity = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    assert!(!entity.has_component(power_grid::component_id()));
    ts::return_shared(entity);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = power_grid::EModulesConnected)]
fun uninstall_with_connected_module_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_grid(&mut scenario, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);
    uninstall_grid(&mut scenario, entity_id);

    abort
}

#[test, expected_failure(abort_code = power_grid::EPowerSourcesPresent)]
fun uninstall_with_generator_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[OUTPUT], vector[CONTAINMENT], &clock);
    uninstall_grid(&mut scenario, entity_id);

    abort
}

#[test, expected_failure(abort_code = power_grid::EComponentMissing)]
fun view_without_grid_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let _entity_id = bare_entity(&mut scenario);
    ts::next_tx(&mut scenario, owner());
    let entity = ts::take_shared<Entity>(&scenario);
    let _grid = power_grid::power_grid(&entity);

    abort
}

// === Grid checks ===

#[test]
fun check_passes_for_off_empty_grid() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_grid(&mut scenario, &clock);

    temp_action!(
        &mut scenario,
        entity_id,
        power_grid::power_grid_requirement(
            false,
            option::none(),
            option::none(),
            0,
            option::none(),
        ),
        |entity, req| power_grid::assert_power_grid(entity, req, &clock),
    );

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = power_grid::EGridState)]
fun check_aborts_when_on_required() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_grid(&mut scenario, &clock);

    temp_action!(
        &mut scenario,
        entity_id,
        power_grid::power_grid_requirement(true, option::none(), option::none(), 0, option::none()),
        |entity, req| power_grid::assert_power_grid(entity, req, &clock),
    );

    abort
}

#[test, expected_failure(abort_code = power_grid::EFuelBelowMin)]
fun check_aborts_when_fuel_below() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_grid(&mut scenario, &clock);

    temp_action!(
        &mut scenario,
        entity_id,
        power_grid::power_grid_requirement(
            false,
            option::some(starting_units() + 1),
            option::none(),
            0,
            option::none(),
        ),
        |entity, req| power_grid::assert_power_grid(entity, req, &clock),
    );

    abort
}

#[test, expected_failure(abort_code = power_grid::EImpulseBelowMin)]
fun check_aborts_when_impulse_below() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_grid(&mut scenario, &clock);

    temp_action!(
        &mut scenario,
        entity_id,
        power_grid::power_grid_requirement(
            false,
            option::none(),
            option::some(IMPULSE + 1),
            0,
            option::none(),
        ),
        |entity, req| power_grid::assert_power_grid(entity, req, &clock),
    );

    abort
}

#[test, expected_failure(abort_code = power_grid::ECapacityBelowMin)]
fun check_aborts_when_capacity_below() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_grid(&mut scenario, &clock);

    temp_action!(
        &mut scenario,
        entity_id,
        power_grid::power_grid_requirement(
            false,
            option::none(),
            option::none(),
            1,
            option::none(),
        ),
        |entity, req| power_grid::assert_power_grid(entity, req, &clock),
    );

    abort
}

#[test, expected_failure(abort_code = power_grid::EUsedAboveMax)]
fun check_aborts_when_used_above() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[OUTPUT], vector[CONTAINMENT], &clock);
    grid_scenario::power_up(&mut scenario, entity_id, 1, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);
    grid_scenario::set_desired(&mut scenario, entity_id, MOD_A, true, &clock);

    temp_action!(
        &mut scenario,
        entity_id,
        power_grid::power_grid_requirement(
            true,
            option::none(),
            option::none(),
            0,
            option::some(0),
        ),
        |entity, req| power_grid::assert_power_grid(entity, req, &clock),
    );

    abort
}
