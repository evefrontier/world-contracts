/// Switching anything on or off, and the online check, need a Shell aboard.
#[test_only]
module power::shell_tests;

use core::test_helpers::setup;
use power::{
    grid_load,
    grid_scenario::{
        clear_shell,
        firm_power,
        fuel_bay_id,
        install_module,
        power,
        power_up,
        seat_shell,
        set_desired,
        set_fuel_bay,
        set_generator,
        setup_entity,
        temp_action
    },
    power_grid
};
use sui::{clock::{Self, Clock}, test_scenario as ts};

const MOD_A: u64 = 401;
/// 15 MW at `SCALE`.
const OUTPUT: u64 = 15_000_000_000;
/// 10 MW at `SCALE`.
const DRAW: u64 = 10_000_000_000;
/// Impulse limit 100, above the test fuel's impulse, so it never caps.
const IMPULSE_LIMIT: u64 = 100_000_000_000;

// === Helpers ===

/// Grid on, one online Generator, `MOD_A` drawing.
fun running(scenario: &mut ts::Scenario, clock: &Clock): ID {
    let entity_id = setup_entity(scenario, vector[OUTPUT], vector[IMPULSE_LIMIT], clock);
    power_up(scenario, entity_id, 1, clock);
    install_module(scenario, entity_id, MOD_A, firm_power(DRAW), clock);
    set_desired(scenario, entity_id, MOD_A, true, clock);
    entity_id
}

/// Running, then the Shell leaves.
fun running_without_shell(scenario: &mut ts::Scenario, clock: &Clock): ID {
    let entity_id = running(scenario, clock);
    clear_shell(scenario, entity_id);
    entity_id
}

fun check_online(scenario: &mut ts::Scenario, entity_id: ID, clock: &Clock) {
    temp_action!(
        scenario,
        entity_id,
        power_grid::online_requirement(MOD_A, DRAW, power_grid::firm()),
        |entity, req| grid_load::assert_online(entity, req, clock),
    );
}

// === Switching on ===

#[test, expected_failure(abort_code = power_grid::ENoShell)]
fun power_on_without_shell_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[OUTPUT], vector[IMPULSE_LIMIT], &clock);
    clear_shell(&mut scenario, entity_id);

    power(&mut scenario, entity_id, true, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::ENoShell)]
fun generator_online_without_shell_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[OUTPUT], vector[IMPULSE_LIMIT], &clock);
    clear_shell(&mut scenario, entity_id);

    set_generator(&mut scenario, entity_id, 0, true, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::ENoShell)]
fun fuel_bay_online_without_shell_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[OUTPUT], vector[IMPULSE_LIMIT], &clock);
    set_fuel_bay(&mut scenario, entity_id, fuel_bay_id(), false, &clock);
    clear_shell(&mut scenario, entity_id);

    set_fuel_bay(&mut scenario, entity_id, fuel_bay_id(), true, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::ENoShell)]
fun module_online_without_shell_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[OUTPUT], vector[IMPULSE_LIMIT], &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);
    clear_shell(&mut scenario, entity_id);

    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);

    abort
}

// === Switching off ===

#[test, expected_failure(abort_code = power_grid::ENoShell)]
fun power_off_without_shell_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = running_without_shell(&mut scenario, &clock);

    power(&mut scenario, entity_id, false, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::ENoShell)]
fun generator_offline_without_shell_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = running_without_shell(&mut scenario, &clock);

    set_generator(&mut scenario, entity_id, 0, false, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::ENoShell)]
fun fuel_bay_offline_without_shell_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = running_without_shell(&mut scenario, &clock);

    set_fuel_bay(&mut scenario, entity_id, fuel_bay_id(), false, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::ENoShell)]
fun module_offline_without_shell_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = running_without_shell(&mut scenario, &clock);

    set_desired(&mut scenario, entity_id, MOD_A, false, &clock);

    abort
}

// === Reseating ===

/// A new Shell lets things be switched on again.
#[test]
fun reseated_shell_switches_on() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[OUTPUT], vector[IMPULSE_LIMIT], &clock);
    clear_shell(&mut scenario, entity_id);
    seat_shell(&mut scenario, entity_id);

    power_up(&mut scenario, entity_id, 1, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);
    check_online(&mut scenario, entity_id, &clock);

    clock.destroy_for_testing();
    scenario.end();
}

// === Online check ===

/// A module still granted when its Shell leaves, before any shut down, fails the
/// online check.
#[test, expected_failure(abort_code = power_grid::ENoShell)]
fun online_check_without_shell_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = running(&mut scenario, &clock);
    check_online(&mut scenario, entity_id, &clock);
    clear_shell(&mut scenario, entity_id);

    check_online(&mut scenario, entity_id, &clock);

    abort
}
