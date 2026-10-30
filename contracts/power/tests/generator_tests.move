#[test_only]
module power::generator_tests;

use core::{admin_service, entity::Entity, test_helpers::{setup, take_acl}};
use power::{
    grid_generator,
    grid_scenario::{Self, admin, generator_id, power, set_generator, setup_entity, temp_action},
    power_grid
};
use sui::{clock::{Self, Clock}, test_scenario as ts};

/// Containment reduction 10.
const CONTAINMENT: u64 = 10;
/// 10 MW and 5 MW.
const OUTPUT_A: u64 = 10;
const OUTPUT_B: u64 = 5;

/// Grid with Generators A (`OUTPUT_A`) and B (`OUTPUT_B`), off.
fun two_generators(scenario: &mut ts::Scenario, clock: &Clock): ID {
    setup_entity(scenario, vector[OUTPUT_A, OUTPUT_B], vector[CONTAINMENT, CONTAINMENT], clock)
}

/// `(online, max_output_mw)` of Generator `index`.
fun generator_flags(scenario: &mut ts::Scenario, entity_id: ID, index: u64): (bool, u64) {
    ts::next_tx(scenario, admin());
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let state = power_grid::generator_state(&entity, generator_id(index));
    let online = state.online();
    let output = state.max_output_mw();
    ts::return_shared(entity);
    (online, output)
}

/// Admin uninstalls Generator `index`.
fun uninstall_generator(scenario: &mut ts::Scenario, entity_id: ID, index: u64, clock: &Clock) {
    ts::next_tx(scenario, admin());
    let mut entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let acl = take_acl(scenario);
    let mut req = grid_generator::uninstall(
        &mut entity,
        generator_id(index),
        clock,
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    ts::return_shared(acl);
    ts::return_shared(entity);
}

#[test]
fun install_connects_offline() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_generators(&mut scenario, &clock);

    let (online_a, output_a) = generator_flags(&mut scenario, entity_id, 0);
    let (online_b, output_b) = generator_flags(&mut scenario, entity_id, 1);
    assert!(!online_a && output_a == OUTPUT_A);
    assert!(!online_b && output_b == OUTPUT_B);

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun online_generators_sum_capacity() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_generators(&mut scenario, &clock);
    power(&mut scenario, entity_id, true, &clock);
    set_generator(&mut scenario, entity_id, 0, true, &clock);
    set_generator(&mut scenario, entity_id, 1, true, &clock);

    let (_, capacity, _, _) = grid_scenario::projected(&mut scenario, entity_id, &clock);
    assert!(capacity == OUTPUT_A + OUTPUT_B);

    set_generator(&mut scenario, entity_id, 1, false, &clock);
    let (_, capacity, _, _) = grid_scenario::projected(&mut scenario, entity_id, &clock);
    assert!(capacity == OUTPUT_A);

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun uninstall_after_offline_disconnects() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_generators(&mut scenario, &clock);
    uninstall_generator(&mut scenario, entity_id, 1, &clock);

    ts::next_tx(&mut scenario, admin());
    let entity = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    assert!(!power_grid::is_generator_connected(&entity, generator_id(1)));
    assert!(power_grid::is_generator_connected(&entity, generator_id(0)));
    ts::return_shared(entity);

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun uninstall_while_online_drops_capacity() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_generators(&mut scenario, &clock);
    power(&mut scenario, entity_id, true, &clock);
    set_generator(&mut scenario, entity_id, 0, true, &clock);
    set_generator(&mut scenario, entity_id, 1, true, &clock);

    uninstall_generator(&mut scenario, entity_id, 0, &clock);

    ts::next_tx(&mut scenario, admin());
    let entity = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    assert!(!power_grid::is_generator_connected(&entity, generator_id(0)));
    assert!(power_grid::generator_state(&entity, generator_id(1)).online());
    ts::return_shared(entity);

    let (_, capacity, _, _) = grid_scenario::projected(&mut scenario, entity_id, &clock);
    assert!(capacity == OUTPUT_B);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = grid_generator::EGeneratorNotConnected)]
fun online_not_connected_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_generators(&mut scenario, &clock);
    set_generator(&mut scenario, entity_id, 5, true, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_generator::EGeneratorAlreadyOnline)]
fun online_twice_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_generators(&mut scenario, &clock);
    set_generator(&mut scenario, entity_id, 0, true, &clock);
    set_generator(&mut scenario, entity_id, 0, true, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_generator::EGeneratorAlreadyOffline)]
fun offline_while_offline_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_generators(&mut scenario, &clock);
    set_generator(&mut scenario, entity_id, 0, false, &clock);

    abort
}

#[test]
fun check_passes_for_offline_generator() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_generators(&mut scenario, &clock);

    temp_action!(
        &mut scenario,
        entity_id,
        power_grid::generator_requirement(generator_id(0), false, option::none(), option::none()),
        |entity, req| grid_generator::assert_generator(entity, req),
    );

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = grid_generator::EGeneratorNotOnline)]
fun check_aborts_when_online_required() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_generators(&mut scenario, &clock);

    temp_action!(
        &mut scenario,
        entity_id,
        power_grid::generator_requirement(generator_id(0), true, option::none(), option::none()),
        |entity, req| grid_generator::assert_generator(entity, req),
    );

    abort
}

#[test, expected_failure(abort_code = grid_generator::EOutputBelowMin)]
fun check_aborts_when_output_below() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_generators(&mut scenario, &clock);

    temp_action!(
        &mut scenario,
        entity_id,
        power_grid::generator_requirement(
            generator_id(0),
            false,
            option::some(OUTPUT_A + 1),
            option::none(),
        ),
        |entity, req| grid_generator::assert_generator(entity, req),
    );

    abort
}

#[test, expected_failure(abort_code = grid_generator::EContainmentBelowMin)]
fun check_aborts_when_containment_below() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_generators(&mut scenario, &clock);

    temp_action!(
        &mut scenario,
        entity_id,
        power_grid::generator_requirement(
            generator_id(0),
            false,
            option::none(),
            option::some(CONTAINMENT + 1),
        ),
        |entity, req| grid_generator::assert_generator(entity, req),
    );

    abort
}
