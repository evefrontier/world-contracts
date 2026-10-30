#[test_only]
module power::shut_down_tests;

use core::{entity::Entity, test_helpers::setup};
use power::{
    grid_scenario::{
        admin,
        draw,
        enable_fuel_module,
        enable_shut_down,
        firm_power,
        fuel_bay_id,
        fuel_module,
        generator_id,
        install_module,
        owner,
        power,
        power_up,
        projected,
        set_desired,
        set_fuel_bay,
        set_fuel_module,
        set_generator,
        setup_entity,
        shut_down
    },
    power_grid::{Self, GridShutDown}
};
use sui::{clock::{Self, Clock}, event, test_scenario as ts};

const MOD_A: u64 = 401;
const LEAP: u64 = 411;
/// 15 MW.
const OUTPUT: u64 = 15;
/// 10 MW.
const DRAW: u64 = 10;
/// Containment reduction 10.
const CONTAINMENT: u64 = 10;
const LEAP_RATE: u64 = 5_680;

// === Helpers ===

/// Grid on, one online Generator, `MOD_A` drawing and a leap module burning.
fun running(scenario: &mut ts::Scenario, clock: &Clock): ID {
    let entity_id = setup_entity(scenario, vector[OUTPUT], vector[CONTAINMENT], clock);
    power_up(scenario, entity_id, 1, clock);
    install_module(scenario, entity_id, MOD_A, firm_power(DRAW), clock);
    set_desired(scenario, entity_id, MOD_A, true, clock);
    install_module(scenario, entity_id, LEAP, fuel_module(), clock);
    enable_fuel_module(scenario, entity_id);
    set_fuel_module(scenario, admin(), entity_id, LEAP, true, LEAP_RATE, clock);
    enable_shut_down(scenario, entity_id);
    entity_id
}

/// `(grid on, generator 0 online, default bay online, MOD_A desired, LEAP desired)`.
fun flags(scenario: &mut ts::Scenario, entity_id: ID): (bool, bool, bool, bool, bool) {
    ts::next_tx(scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let grid = power_grid::power_grid(&entity);
    let on = grid.on();
    let generator_online = power_grid::generator_state(&entity, generator_id(0)).online();
    let bay_online = power_grid::fuel_bay_state(&entity, fuel_bay_id()).bay_online();
    let mod_desired = grid.module_state(MOD_A).desired_online();
    let leap_desired = grid.module_state(LEAP).desired_online();
    ts::return_shared(entity);
    (on, generator_online, bay_online, mod_desired, leap_desired)
}

// === Shut down ===

/// Shut down clears every intent and takes every source offline; the grid stays on.
#[test]
fun shut_down_clears_intent_and_takes_sources_offline() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = running(&mut scenario, &clock);

    shut_down(&mut scenario, admin(), entity_id, &clock);

    assert!(event::events_by_type<GridShutDown>().length() == 1);
    let (on, generator_online, bay_online, mod_desired, leap_desired) = flags(
        &mut scenario,
        entity_id,
    );
    assert!(on && !generator_online && !bay_online && !mod_desired && !leap_desired);
    let (left_now, _, _, _) = projected(&mut scenario, entity_id, &clock);
    clock.set_for_testing(1_000_000);
    let (fuel_left, capacity, used, online) = projected(&mut scenario, entity_id, &clock);
    assert!(fuel_left == left_now && capacity == 0 && used == 0 && online.is_empty());
    assert!(draw(&mut scenario, entity_id, LEAP, &clock) == 0);

    clock.destroy_for_testing();
    scenario.end();
}

/// Power Off keeps intent, so Power On brings modules back. Shut down clears it,
/// so a power cycle brings nothing back.
#[test]
fun power_off_keeps_intent_shut_down_clears_it() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = running(&mut scenario, &clock);

    power(&mut scenario, entity_id, false, &clock);
    power(&mut scenario, entity_id, true, &clock);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == DRAW);
    assert!(draw(&mut scenario, entity_id, LEAP, &clock) == LEAP_RATE);

    shut_down(&mut scenario, admin(), entity_id, &clock);
    power(&mut scenario, entity_id, false, &clock);
    power(&mut scenario, entity_id, true, &clock);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == 0);
    assert!(draw(&mut scenario, entity_id, LEAP, &clock) == 0);

    clock.destroy_for_testing();
    scenario.end();
}

/// After a shut down the owner switches things on again, step by step.
#[test]
fun owner_brings_creation_back_after_shut_down() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = running(&mut scenario, &clock);
    shut_down(&mut scenario, admin(), entity_id, &clock);

    set_fuel_bay(&mut scenario, entity_id, fuel_bay_id(), true, &clock);
    set_generator(&mut scenario, entity_id, 0, true, &clock);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == 0);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == DRAW);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = core::admin_service::EUnauthorizedAdmin)]
fun shut_down_by_non_admin_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = running(&mut scenario, &clock);

    shut_down(&mut scenario, owner(), entity_id, &clock);

    abort
}
