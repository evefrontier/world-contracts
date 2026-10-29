#[test_only]
module power::status_tests;

use core::{entity::Entity, test_helpers::setup};
use power::{
    grid_scenario::{
        admin,
        enable_fuel_module,
        firm_power,
        fuel_bay_id,
        fuel_capacity,
        fuel_module,
        generator_id,
        impulse,
        burden,
        install_fuel,
        install_module,
        owner,
        power,
        power_up,
        deposit_fuel_into,
        set_desired,
        set_fuel_bay,
        set_fuel_module,
        set_generator,
        setup_entity
    },
    power_grid::{Self, PowerStatus}
};
use sui::{clock::{Self, Clock}, test_scenario as ts};

const MOD_A: u64 = 401;
const MOD_B: u64 = 402;
const LEAP: u64 = 411;
const FUEL_B: u64 = 9_002;
/// 15 MW.
const OUTPUT: u64 = 15;
/// 10 MW.
const DRAW: u64 = 10;
/// Containment reduction 10.
const CONTAINMENT: u64 = 10;
/// Long enough at 10 MW that the whole bay burns, in ms.
const DEPLETING_MS: u64 = 10_000_000_000_000;

// === Helpers ===

/// Grid on, one online Generator of `OUTPUT`, `MOD_A` desired and drawing.
fun running(scenario: &mut ts::Scenario, clock: &Clock): ID {
    let entity_id = setup_entity(scenario, vector[OUTPUT], vector[CONTAINMENT], clock);
    power_up(scenario, entity_id, 1, clock);
    install_module(scenario, entity_id, MOD_A, firm_power(DRAW), clock);
    set_desired(scenario, entity_id, MOD_A, true, clock);
    entity_id
}

fun module_status(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    module_id: u64,
    clock: &Clock,
): PowerStatus {
    ts::next_tx(scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let status = power_grid::module_status(&entity, module_id, clock);
    ts::return_shared(entity);
    status
}

fun generator_status(scenario: &mut ts::Scenario, entity_id: ID, clock: &Clock): PowerStatus {
    ts::next_tx(scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let status = power_grid::generator_status(&entity, generator_id(0), clock);
    ts::return_shared(entity);
    status
}

// === Modules ===

#[test]
fun running_module_reads_online() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = running(&mut scenario, &clock);

    assert!(module_status(&mut scenario, entity_id, MOD_A, &clock) == power_grid::online_status());
    assert!(generator_status(&mut scenario, entity_id, &clock) == power_grid::online_status());

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun switched_off_module_reads_off() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = running(&mut scenario, &clock);

    set_desired(&mut scenario, entity_id, MOD_A, false, &clock);
    set_generator(&mut scenario, entity_id, 0, false, &clock);

    assert!(module_status(&mut scenario, entity_id, MOD_A, &clock) == power_grid::off_status());
    assert!(generator_status(&mut scenario, entity_id, &clock) == power_grid::off_status());

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun power_off_reads_grid_off() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = running(&mut scenario, &clock);

    power(&mut scenario, entity_id, false, &clock);

    assert!(
        module_status(&mut scenario, entity_id, MOD_A, &clock) == power_grid::grid_off_status(),
    );
    assert!(generator_status(&mut scenario, entity_id, &clock) == power_grid::grid_off_status());

    clock.destroy_for_testing();
    scenario.end();
}

/// A second Firm module that doesn't fit overloads the grid: both read `NoPower`.
#[test]
fun overload_reads_no_power() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = running(&mut scenario, &clock);
    install_module(&mut scenario, entity_id, MOD_B, firm_power(DRAW), &clock);

    set_desired(&mut scenario, entity_id, MOD_B, true, &clock);

    assert!(
        module_status(&mut scenario, entity_id, MOD_A, &clock) == power_grid::no_power_status(),
    );
    assert!(
        module_status(&mut scenario, entity_id, MOD_B, &clock) == power_grid::no_power_status(),
    );
    assert!(generator_status(&mut scenario, entity_id, &clock) == power_grid::online_status());

    clock.destroy_for_testing();
    scenario.end();
}

/// The only bay ran dry: modules and the still-online Generator read `NoFuel`.
#[test]
fun dry_bays_read_no_fuel() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = running(&mut scenario, &clock);

    clock.set_for_testing(DEPLETING_MS);

    assert!(module_status(&mut scenario, entity_id, MOD_A, &clock) == power_grid::no_fuel_status());
    assert!(generator_status(&mut scenario, entity_id, &clock) == power_grid::no_fuel_status());

    clock.destroy_for_testing();
    scenario.end();
}

/// The online bay is empty but a reserve bay holds fuel: `BaysOffline`.
#[test]
fun fuel_only_offline_reads_bays_offline() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = running(&mut scenario, &clock);
    install_fuel(&mut scenario, entity_id, FUEL_B, fuel_capacity(), &clock);
    deposit_fuel_into(&mut scenario, entity_id, FUEL_B, 100, impulse(), burden(), 1, &clock);

    clock.set_for_testing(DEPLETING_MS);

    assert!(
        module_status(&mut scenario, entity_id, MOD_A, &clock) == power_grid::bays_offline_status(),
    );
    assert!(
        generator_status(&mut scenario, entity_id, &clock) == power_grid::bays_offline_status(),
    );
    set_fuel_bay(&mut scenario, entity_id, FUEL_B, true, &clock);
    assert!(module_status(&mut scenario, entity_id, MOD_A, &clock) == power_grid::online_status());

    clock.destroy_for_testing();
    scenario.end();
}

/// A switch-on with every bay offline is accepted and reads `BaysOffline`.
#[test]
fun switch_on_with_bays_offline_reads_bays_offline() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[OUTPUT], vector[CONTAINMENT], &clock);
    power_up(&mut scenario, entity_id, 1, &clock);
    set_fuel_bay(&mut scenario, entity_id, fuel_bay_id(), false, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);

    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);

    assert!(
        module_status(&mut scenario, entity_id, MOD_A, &clock) == power_grid::bays_offline_status(),
    );

    clock.destroy_for_testing();
    scenario.end();
}

// === Fuel modules ===

/// A fuel module reads `Online` with fuel and `NoFuel` once the bays run dry.
#[test]
fun fuel_module_reads_online_then_no_fuel() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = running(&mut scenario, &clock);
    install_module(&mut scenario, entity_id, LEAP, fuel_module(), &clock);
    enable_fuel_module(&mut scenario, entity_id);

    assert!(module_status(&mut scenario, entity_id, LEAP, &clock) == power_grid::off_status());
    set_fuel_module(&mut scenario, admin(), entity_id, LEAP, true, 5_680, &clock);
    assert!(module_status(&mut scenario, entity_id, LEAP, &clock) == power_grid::online_status());
    clock.set_for_testing(DEPLETING_MS);
    assert!(module_status(&mut scenario, entity_id, LEAP, &clock) == power_grid::no_fuel_status());

    clock.destroy_for_testing();
    scenario.end();
}

/// `module_statuses` lists every connected module.
#[test]
fun module_statuses_lists_every_module() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = running(&mut scenario, &clock);
    install_module(&mut scenario, entity_id, MOD_B, firm_power(DRAW), &clock);

    ts::next_tx(&mut scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    let statuses = power_grid::module_statuses(&entity, &clock);
    assert!(statuses.length() == 2);
    let (mod_a, mod_b) = (MOD_A, MOD_B);
    assert!(statuses[&mod_a] == power_grid::online_status());
    assert!(statuses[&mod_b] == power_grid::off_status());
    ts::return_shared(entity);

    clock.destroy_for_testing();
    scenario.end();
}
