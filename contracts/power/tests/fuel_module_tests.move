#[test_only]
module power::fuel_module_tests;

use core::test_helpers::setup;
use power::{
    grid_load::{Self, FuelModuleToggled},
    grid_scenario::{
        admin,
        draw,
        enable_fuel_module,
        firm_power,
        fuel_module,
        install_module,
        migrate_module,
        owner,
        power,
        power_up,
        projected,
        set_desired,
        set_fuel_module,
        setup_empty_grid,
        setup_entity,
        starting_fuel,
        stored_draw
    },
    power_grid
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
/// The overview's leap use, 0.568 per second at `SCALE`.
const LEAP_RATE: u64 = 5_680;
/// 10 MW at factor 64.2857 over 10 s, at `SCALE`.
const GENERATOR_BURN_10S: u64 = 15_556;

// === Helpers ===

/// Grid on, one online Generator of `OUTPUT`, `MOD_A` drawing `DRAW`, and a
/// connected leap module the admin can switch.
fun with_leap(scenario: &mut ts::Scenario, clock: &Clock): ID {
    let entity_id = setup_entity(scenario, vector[OUTPUT], vector[CONTAINMENT], clock);
    power_up(scenario, entity_id, 1, clock);
    install_module(scenario, entity_id, MOD_A, firm_power(DRAW), clock);
    set_desired(scenario, entity_id, MOD_A, true, clock);
    install_module(scenario, entity_id, LEAP, fuel_module(), clock);
    enable_fuel_module(scenario, entity_id);
    entity_id
}

// === Burn ===

/// Total burn is the generator's plus the leap rate: 15_556 + 56_800 over 10 s.
#[test]
fun fuel_module_rate_adds_to_burn() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = with_leap(&mut scenario, &clock);

    set_fuel_module(&mut scenario, admin(), entity_id, LEAP, true, LEAP_RATE, &clock);
    clock.set_for_testing(10_000);

    let (fuel_left, _, used, online) = projected(&mut scenario, entity_id, &clock);
    assert!(fuel_left == starting_fuel() - GENERATOR_BURN_10S - 10 * LEAP_RATE);
    assert!(used == DRAW);
    assert!(online == vector[MOD_A, LEAP]);
    assert!(draw(&mut scenario, entity_id, LEAP, &clock) == LEAP_RATE);

    clock.destroy_for_testing();
    scenario.end();
}

/// A fuel module burns with no generator and no power module.
#[test]
fun fuel_module_burns_without_power() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    power(&mut scenario, entity_id, true, &clock);
    install_module(&mut scenario, entity_id, LEAP, fuel_module(), &clock);
    enable_fuel_module(&mut scenario, entity_id);

    set_fuel_module(&mut scenario, admin(), entity_id, LEAP, true, 10_000, &clock);

    let toggled = event::events_by_type<FuelModuleToggled>();
    let (_, toggled_module, toggled_online, toggled_rate) = toggled[0].fuel_module_toggled_fields();
    assert!(toggled_module == LEAP && toggled_online && toggled_rate == 10_000);
    clock.set_for_testing(10_000);
    let (fuel_left, capacity, used, _) = projected(&mut scenario, entity_id, &clock);
    assert!(fuel_left == starting_fuel() - 100_000);
    assert!(capacity == 0 && used == 0);

    clock.destroy_for_testing();
    scenario.end();
}

/// Switching the module offline stops its burn.
#[test]
fun fuel_module_offline_stops_its_burn() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = with_leap(&mut scenario, &clock);
    set_fuel_module(&mut scenario, admin(), entity_id, LEAP, true, LEAP_RATE, &clock);
    set_fuel_module(&mut scenario, admin(), entity_id, LEAP, false, 0, &clock);

    clock.set_for_testing(10_000);

    let (fuel_left, _, _, online) = projected(&mut scenario, entity_id, &clock);
    assert!(fuel_left == starting_fuel() - GENERATOR_BURN_10S);
    assert!(online == vector[MOD_A]);
    assert!(stored_draw(&mut scenario, entity_id, LEAP) == 0);

    clock.destroy_for_testing();
    scenario.end();
}

/// Power Off stops a fuel module's burn and keeps its rate for Power On.
#[test]
fun power_off_stops_fuel_module_and_keeps_its_rate() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = with_leap(&mut scenario, &clock);
    set_fuel_module(&mut scenario, admin(), entity_id, LEAP, true, LEAP_RATE, &clock);
    power(&mut scenario, entity_id, false, &clock);

    clock.set_for_testing(10_000);
    let (fuel_left, _, _, online) = projected(&mut scenario, entity_id, &clock);
    assert!(fuel_left == starting_fuel() && online.is_empty());
    assert!(draw(&mut scenario, entity_id, LEAP, &clock) == 0);

    power(&mut scenario, entity_id, true, &clock);
    assert!(draw(&mut scenario, entity_id, LEAP, &clock) == LEAP_RATE);

    clock.destroy_for_testing();
    scenario.end();
}

/// A fuel module takes no power: a Firm module that fills the limit still fits.
#[test]
fun fuel_module_takes_no_power() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[DRAW], vector[CONTAINMENT], &clock);
    power_up(&mut scenario, entity_id, 1, &clock);
    install_module(&mut scenario, entity_id, LEAP, fuel_module(), &clock);
    enable_fuel_module(&mut scenario, entity_id);
    set_fuel_module(&mut scenario, admin(), entity_id, LEAP, true, LEAP_RATE, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);

    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);

    let (_, capacity, used, _) = projected(&mut scenario, entity_id, &clock);
    assert!(capacity == DRAW && used == DRAW);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == DRAW);

    clock.destroy_for_testing();
    scenario.end();
}

/// Once the online bays run dry, the fuel module gets nothing.
#[test]
fun dry_bays_give_fuel_module_nothing() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = with_leap(&mut scenario, &clock);
    set_fuel_module(&mut scenario, admin(), entity_id, LEAP, true, LEAP_RATE, &clock);

    clock.set_for_testing(10_000_000_000);

    let (fuel_left, _, _, online) = projected(&mut scenario, entity_id, &clock);
    assert!(fuel_left == 0 && online.is_empty());
    assert!(draw(&mut scenario, entity_id, LEAP, &clock) == 0);

    clock.destroy_for_testing();
    scenario.end();
}

/// A migrated fuel module keeps its desired state and rate.
#[test]
fun migrate_keeps_fuel_module_rate() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let from = with_leap(&mut scenario, &clock);
    set_fuel_module(&mut scenario, admin(), from, LEAP, true, LEAP_RATE, &clock);
    let to = setup_empty_grid(&mut scenario, 2, &clock);

    migrate_module(&mut scenario, admin(), from, to, LEAP, true, &clock);

    assert!(stored_draw(&mut scenario, to, LEAP) == LEAP_RATE);

    clock.destroy_for_testing();
    scenario.end();
}

// === Aborts ===

#[test, expected_failure(abort_code = grid_load::ENotPowerModule)]
fun owner_cannot_set_desired_state_on_fuel_module() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = with_leap(&mut scenario, &clock);

    set_desired(&mut scenario, entity_id, LEAP, true, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_load::ENotFuelModule)]
fun set_fuel_module_on_power_module_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = with_leap(&mut scenario, &clock);

    set_fuel_module(&mut scenario, admin(), entity_id, MOD_A, true, LEAP_RATE, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_load::EZeroFuelRate)]
fun fuel_module_online_at_zero_rate_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = with_leap(&mut scenario, &clock);

    set_fuel_module(&mut scenario, admin(), entity_id, LEAP, true, 0, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_load::EFuelRateTooHigh)]
fun fuel_module_rate_above_max_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = with_leap(&mut scenario, &clock);

    let rate = power_grid::max_fuel_rate() + 1;
    set_fuel_module(&mut scenario, admin(), entity_id, LEAP, true, rate, &clock);

    abort
}

#[test, expected_failure(abort_code = core::admin_service::EUnauthorizedAdmin)]
fun set_fuel_module_by_non_admin_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = with_leap(&mut scenario, &clock);

    set_fuel_module(&mut scenario, owner(), entity_id, LEAP, true, LEAP_RATE, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_load::EFuelModuleNeedsPower)]
fun fuel_module_with_power_req_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);

    install_module(
        &mut scenario,
        entity_id,
        LEAP,
        power_grid::module_power_spec(5, power_grid::firm(), power_grid::fuel_kind(), 0, 0),
        &clock,
    );

    abort
}
