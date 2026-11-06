#[test_only]
module power::generator_tests;

use core::{admin_service, entity::Entity, test_helpers::{setup, take_acl}};
use power::{
    grid_generator,
    grid_scenario::{
        Self,
        admin,
        generator_id,
        install_generator,
        power,
        set_generator,
        set_generator_fuel_type,
        setup_entity,
        temp_action
    },
    power_grid
};
use sui::{clock::{Self, Clock}, event, test_scenario as ts};

/// Impulse limit 100, above the test fuel's impulse, so it never caps.
const IMPULSE_LIMIT: u64 = 1_000_000;
/// 10 MW and 5 MW.
const OUTPUT_A: u64 = 10;
const OUTPUT_B: u64 = 5;
/// An Emergency Generator that can burn either type.
const EMERGENCY: u64 = 9_101;
const HYDROGEN: u64 = 1;
const CRUDE: u64 = 2;
/// 20 MW, impulse limit 50, volatility limit 2, all at `SCALE` where scaled.
const EMERGENCY_OUTPUT: u64 = 20;
const EMERGENCY_IMPULSE_LIMIT: u64 = 500_000;
const EMERGENCY_VOLATILITY_LIMIT: u64 = 20_000;

/// Grid with Generators A (`OUTPUT_A`) and B (`OUTPUT_B`), off.
fun two_generators(scenario: &mut ts::Scenario, clock: &Clock): ID {
    setup_entity(scenario, vector[OUTPUT_A, OUTPUT_B], vector[IMPULSE_LIMIT, IMPULSE_LIMIT], clock)
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
        power_grid::generator_requirement(generator_id(0), false, option::none()),
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
        power_grid::generator_requirement(generator_id(0), true, option::none()),
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
        ),
        |entity, req| grid_generator::assert_generator(entity, req),
    );

    abort
}

// === Fuel type and limits ===

/// A grid with an offline Emergency Generator burning Hydrogen, selectable Hydrogen or Crude.
fun with_emergency(scenario: &mut ts::Scenario, clock: &Clock): ID {
    let entity_id = setup_entity(scenario, vector[], vector[], clock);
    install_emergency(scenario, entity_id, HYDROGEN, vector[HYDROGEN, CRUDE], clock);
    entity_id
}

fun install_emergency(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    fuel_type: u64,
    selectable: vector<u64>,
    clock: &Clock,
) {
    install_generator(
        scenario,
        entity_id,
        EMERGENCY,
        fuel_type,
        selectable,
        EMERGENCY_OUTPUT,
        EMERGENCY_IMPULSE_LIMIT,
        EMERGENCY_VOLATILITY_LIMIT,
        clock,
    );
}

fun emergency_state(scenario: &mut ts::Scenario, entity_id: ID): power_grid::GeneratorState {
    ts::next_tx(scenario, admin());
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let state = power_grid::generator_state(&entity, EMERGENCY);
    ts::return_shared(entity);
    state
}

/// Install stores the fuel type, selectable types and limits, and reports them.
#[test]
fun install_stores_fuel_type_and_limits() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = with_emergency(&mut scenario, &clock);

    let connected = event::events_by_type<grid_generator::GeneratorConnected>();
    let (_, id, fuel_type, selectable, output, impulse_limit, volatility_limit) = connected[
        0,
    ].generator_connected_fields();
    assert!(id == EMERGENCY && fuel_type == HYDROGEN && selectable == vector[HYDROGEN, CRUDE]);
    assert!(output == EMERGENCY_OUTPUT && impulse_limit == EMERGENCY_IMPULSE_LIMIT);
    assert!(volatility_limit == EMERGENCY_VOLATILITY_LIMIT);
    let state = emergency_state(&mut scenario, entity_id);
    assert!(state.generator_fuel_type() == HYDROGEN && !state.online());
    assert!(state.selectable_fuel_types() == vector[HYDROGEN, CRUDE]);
    assert!(state.impulse_limit() == EMERGENCY_IMPULSE_LIMIT);
    assert!(state.volatility_limit() == EMERGENCY_VOLATILITY_LIMIT);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = grid_generator::EZeroOutput)]
fun install_zero_output_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);

    install_generator(&mut scenario, entity_id, EMERGENCY, HYDROGEN, vector[], 0, 1, 1, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_generator::EZeroImpulseLimit)]
fun install_zero_impulse_limit_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);

    install_generator(&mut scenario, entity_id, EMERGENCY, HYDROGEN, vector[], 1, 0, 1, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_generator::EZeroVolatilityLimit)]
fun install_zero_volatility_limit_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);

    install_generator(&mut scenario, entity_id, EMERGENCY, HYDROGEN, vector[], 1, 1, 0, &clock);

    abort
}

/// The installed type must be one of the selectable types, when any are listed.
#[test, expected_failure(abort_code = grid_generator::EFuelTypeNotSelectable)]
fun install_type_outside_selectable_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);

    install_emergency(&mut scenario, entity_id, HYDROGEN, vector[CRUDE], &clock);

    abort
}

/// The owner switches an offline Emergency Generator to Crude.
#[test]
fun set_fuel_type_switches_an_offline_generator() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = with_emergency(&mut scenario, &clock);

    set_generator_fuel_type(&mut scenario, entity_id, EMERGENCY, CRUDE);

    let changed = event::events_by_type<grid_generator::GeneratorFuelTypeChanged>();
    let (changed_entity, changed_id, changed_type) = changed[
        0,
    ].generator_fuel_type_changed_fields();
    assert!(changed_entity == entity_id && changed_id == EMERGENCY && changed_type == CRUDE);
    assert!(emergency_state(&mut scenario, entity_id).generator_fuel_type() == CRUDE);

    clock.destroy_for_testing();
    scenario.end();
}

/// A fixed-type Generator can't switch.
#[test, expected_failure(abort_code = grid_generator::EFuelTypeNotSelectable)]
fun set_fuel_type_on_fixed_generator_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    install_emergency(&mut scenario, entity_id, HYDROGEN, vector[], &clock);

    set_generator_fuel_type(&mut scenario, entity_id, EMERGENCY, CRUDE);

    abort
}

#[test, expected_failure(abort_code = grid_generator::ESameFuelType)]
fun set_fuel_type_to_current_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = with_emergency(&mut scenario, &clock);

    set_generator_fuel_type(&mut scenario, entity_id, EMERGENCY, HYDROGEN);

    abort
}

/// An online Generator must go offline before it switches type.
#[test, expected_failure(abort_code = grid_generator::EGeneratorOnline)]
fun set_fuel_type_while_online_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = with_emergency(&mut scenario, &clock);
    grid_scenario::as_owner!(
        &mut scenario,
        entity_id,
        b"operate_grid",
        |entity, req| grid_generator::set_generator(entity, req, EMERGENCY, true, &clock),
    );

    set_generator_fuel_type(&mut scenario, entity_id, EMERGENCY, CRUDE);

    abort
}
