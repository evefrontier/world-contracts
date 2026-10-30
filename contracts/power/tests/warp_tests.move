#[test_only]
module power::warp_tests;

use core::test_helpers::setup;
use power::{
    grid_fuel::{Self, FuelWithdrawn},
    grid_scenario::{
        admin,
        bay_fuel,
        burden,
        deposit_fuel_into,
        enable_withdraw,
        firm_power,
        fuel_bay_id,
        fuel_capacity,
        impulse,
        install_fuel,
        install_module,
        owner,
        power_up,
        projected,
        set_desired,
        set_fuel_bay,
        setup_entity,
        starting_fuel,
        volatility,
        withdraw
    }
};
use sui::{clock::{Self, Clock}, event, test_scenario as ts};

const FUEL_B: u64 = 9_002;
const MOD_A: u64 = 401;
/// Plain units: a quarter of the default bay's 50_000.
const QUARTER_UNITS: u64 = 12_500;

// === Helpers ===

/// The default bay (50_000 units) and `FUEL_B` (12_500 units), both online,
/// with the `withdraw_fuel` admin action exposed.
fun two_bays(scenario: &mut ts::Scenario, clock: &Clock): ID {
    let entity_id = setup_entity(scenario, vector[], vector[], clock);
    install_fuel(scenario, entity_id, FUEL_B, fuel_capacity(), clock);
    deposit_fuel_into(
        scenario,
        entity_id,
        FUEL_B,
        QUARTER_UNITS,
        impulse(),
        burden(),
        volatility(),
        clock,
    );
    set_fuel_bay(scenario, entity_id, FUEL_B, true, clock);
    enable_withdraw(scenario, entity_id);
    entity_id
}

// === Withdraw ===

/// Each online bay gives by what it holds: 4/5 and 1/5 of 10 units.
#[test]
fun withdraw_takes_from_online_bays_in_proportion() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_bays(&mut scenario, &clock);

    withdraw(&mut scenario, admin(), entity_id, 100_000, &clock);

    let withdrawn = event::events_by_type<FuelWithdrawn>();
    let (_, quantity, remaining) = withdrawn[0].fuel_withdrawn_fields();
    let total = starting_fuel() + starting_fuel() / 4;
    assert!(quantity == 100_000 && remaining == total - 100_000);
    assert!(
        bay_fuel(&mut scenario, entity_id, fuel_bay_id()).quantity() == starting_fuel() - 80_000,
    );
    assert!(bay_fuel(&mut scenario, entity_id, FUEL_B).quantity() == starting_fuel() / 4 - 20_000);

    clock.destroy_for_testing();
    scenario.end();
}

/// Shares round down; the remainder comes off the largest bay: 3 splits 3 and 0.
#[test]
fun withdraw_remainder_comes_off_the_largest_bay() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_bays(&mut scenario, &clock);

    withdraw(&mut scenario, admin(), entity_id, 3, &clock);

    assert!(bay_fuel(&mut scenario, entity_id, fuel_bay_id()).quantity() == starting_fuel() - 3);
    assert!(bay_fuel(&mut scenario, entity_id, FUEL_B).quantity() == starting_fuel() / 4);

    clock.destroy_for_testing();
    scenario.end();
}

/// An offline bay gives nothing.
#[test]
fun withdraw_leaves_offline_bays_alone() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_bays(&mut scenario, &clock);
    set_fuel_bay(&mut scenario, entity_id, FUEL_B, false, &clock);

    withdraw(&mut scenario, admin(), entity_id, 100_000, &clock);

    assert!(
        bay_fuel(&mut scenario, entity_id, fuel_bay_id()).quantity() == starting_fuel() - 100_000,
    );
    assert!(bay_fuel(&mut scenario, entity_id, FUEL_B).quantity() == starting_fuel() / 4);

    clock.destroy_for_testing();
    scenario.end();
}

/// Withdrawing everything the online bays hold is allowed and cuts power.
#[test]
fun withdraw_everything_after_burn() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[15], vector[10], &clock);
    power_up(&mut scenario, entity_id, 1, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(10), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);
    enable_withdraw(&mut scenario, entity_id);
    clock.set_for_testing(10_000);
    let (left, _, _, _) = projected(&mut scenario, entity_id, &clock);

    withdraw(&mut scenario, admin(), entity_id, left, &clock);

    let (fuel_left, capacity, used, _) = projected(&mut scenario, entity_id, &clock);
    assert!(fuel_left == 0 && capacity == 0 && used == 0);

    clock.destroy_for_testing();
    scenario.end();
}

// === Aborts ===

/// Stored fuel still shows the full bay; the burn must count first, so this is short.
#[test, expected_failure(abort_code = grid_fuel::EFuelShort)]
fun withdraw_more_than_left_after_burn_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[15], vector[10], &clock);
    power_up(&mut scenario, entity_id, 1, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(10), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);
    enable_withdraw(&mut scenario, entity_id);
    clock.set_for_testing(10_000);

    withdraw(&mut scenario, admin(), entity_id, starting_fuel(), &clock);

    abort
}

/// Fuel in an offline bay doesn't count toward a withdrawal.
#[test, expected_failure(abort_code = grid_fuel::EFuelShort)]
fun withdraw_counting_offline_fuel_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_bays(&mut scenario, &clock);
    set_fuel_bay(&mut scenario, entity_id, FUEL_B, false, &clock);

    withdraw(&mut scenario, admin(), entity_id, starting_fuel() + 1, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EZeroFuel)]
fun withdraw_zero_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_bays(&mut scenario, &clock);

    withdraw(&mut scenario, admin(), entity_id, 0, &clock);

    abort
}

#[test, expected_failure(abort_code = core::admin_service::EUnauthorizedAdmin)]
fun withdraw_by_non_admin_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_bays(&mut scenario, &clock);

    withdraw(&mut scenario, owner(), entity_id, 100_000, &clock);

    abort
}
