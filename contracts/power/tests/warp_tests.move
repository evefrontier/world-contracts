#[test_only]
module power::warp_tests;

use core::test_helpers::setup;
use power::{
    grid_fuel::{Self, FuelSiphoned, FuelWithdrawn},
    grid_scenario::{
        admin,
        bay_fuel,
        burden,
        deposit_fuel_into,
        deposit_typed,
        enable_siphon,
        enable_withdraw,
        firm_power,
        fuel_bay_id,
        fuel_capacity,
        fuel_type,
        impulse,
        install_fuel,
        install_module,
        owner,
        power_up,
        projected,
        set_desired,
        set_fuel_bay,
        setup_entity,
        siphon,
        starting_fuel,
        stored_draw,
        thermal,
        volatility,
        withdraw,
        withdraw_type
    },
    power_grid
};
use sui::{clock::{Self, Clock}, event, test_scenario as ts};

const FUEL_B: u64 = 9_002;
const MOD_A: u64 = 401;
/// Plain units: a quarter of the default bay's 50_000.
const QUARTER_UNITS: u64 = 12_500;
const OTHER_TYPE: u64 = 8;
/// Impulse limit 100, above the test fuel's impulse, so it never caps.
const IMPULSE_LIMIT: u64 = 1_000_000;

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
    let (_, withdrawn_type, quantity, remaining) = withdrawn[0].fuel_withdrawn_fields();
    assert!(withdrawn_type == fuel_type());
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
    let entity_id = setup_entity(&mut scenario, vector[15], vector[1_000_000], &clock);
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
    let entity_id = setup_entity(&mut scenario, vector[15], vector[1_000_000], &clock);
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

// === Withdraw by type ===

/// The default bay (`fuel_type()`) and `FUEL_B` holding `QUARTER_UNITS` of
/// `OTHER_TYPE`, both online, with the `withdraw_fuel` admin action exposed.
fun two_types(scenario: &mut ts::Scenario, clock: &Clock): ID {
    let entity_id = setup_entity(scenario, vector[], vector[], clock);
    install_fuel(scenario, entity_id, FUEL_B, fuel_capacity(), clock);
    deposit_typed(
        scenario,
        entity_id,
        FUEL_B,
        OTHER_TYPE,
        QUARTER_UNITS,
        impulse(),
        thermal(),
        clock,
    );
    set_fuel_bay(scenario, entity_id, FUEL_B, true, clock);
    enable_withdraw(scenario, entity_id);
    entity_id
}

/// A withdrawal draws only on its type's pool.
#[test]
fun withdraw_takes_only_its_pool() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_types(&mut scenario, &clock);

    withdraw_type(&mut scenario, admin(), entity_id, OTHER_TYPE, 100_000, &clock);

    let withdrawn = event::events_by_type<FuelWithdrawn>();
    let (_, withdrawn_type, quantity, remaining) = withdrawn[0].fuel_withdrawn_fields();
    let other_held = QUARTER_UNITS * power_grid::scale();
    assert!(withdrawn_type == OTHER_TYPE && quantity == 100_000);
    assert!(remaining == other_held - 100_000);
    assert!(bay_fuel(&mut scenario, entity_id, FUEL_B).quantity() == other_held - 100_000);
    assert!(bay_fuel(&mut scenario, entity_id, fuel_bay_id()).quantity() == starting_fuel());

    clock.destroy_for_testing();
    scenario.end();
}

/// Another type's fuel doesn't count toward a withdrawal.
#[test, expected_failure(abort_code = grid_fuel::EFuelShort)]
fun withdraw_counting_another_type_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_types(&mut scenario, &clock);

    withdraw_type(
        &mut scenario,
        admin(),
        entity_id,
        OTHER_TYPE,
        QUARTER_UNITS * power_grid::scale() + 1,
        &clock,
    );

    abort
}

// === Siphon ===

/// The default bay online, `FUEL_B` offline holding `QUARTER_UNITS`, and the
/// `siphon` admin action exposed.
fun siphon_ready(scenario: &mut ts::Scenario, clock: &Clock): ID {
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
    enable_siphon(scenario, entity_id);
    entity_id
}

/// Part of a bay comes out with the bay's values; the bay keeps its type.
#[test]
fun siphon_takes_part_of_a_bay() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = siphon_ready(&mut scenario, &clock);

    siphon(&mut scenario, admin(), entity_id, fuel_bay_id(), 70_000, &clock);

    let siphoned = event::events_by_type<FuelSiphoned>();
    let (
        siphoned_entity,
        siphoned_bay,
        siphoned_type,
        quantity,
        siphoned_impulse,
        siphoned_volatility,
        siphoned_burden,
        siphoned_thermal,
    ) = siphoned[0].fuel_siphoned_fields();
    assert!(siphoned_entity == entity_id && siphoned_bay == fuel_bay_id());
    assert!(siphoned_type == fuel_type() && quantity == 70_000);
    assert!(siphoned_impulse == impulse() && siphoned_volatility == volatility());
    assert!(siphoned_burden == burden() && siphoned_thermal == thermal());
    let fuel = bay_fuel(&mut scenario, entity_id, fuel_bay_id());
    assert!(fuel.quantity() == starting_fuel() - 70_000);
    assert!(fuel.fuel_type() == option::some(fuel_type()));

    clock.destroy_for_testing();
    scenario.end();
}

/// An offline bay can be siphoned too.
#[test]
fun siphon_an_offline_bay() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = siphon_ready(&mut scenario, &clock);

    siphon(&mut scenario, admin(), entity_id, FUEL_B, 10_000, &clock);

    let held = QUARTER_UNITS * power_grid::scale() - 10_000;
    assert!(bay_fuel(&mut scenario, entity_id, FUEL_B).quantity() == held);

    clock.destroy_for_testing();
    scenario.end();
}

/// Siphoning a running grid's only bay dry clears its type and cuts power.
#[test]
fun siphon_all_clears_the_type_and_cuts_power() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[15], vector[IMPULSE_LIMIT], &clock);
    power_up(&mut scenario, entity_id, 1, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(10), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);
    enable_siphon(&mut scenario, entity_id);
    assert!(stored_draw(&mut scenario, entity_id, MOD_A) == 10);

    siphon(&mut scenario, admin(), entity_id, fuel_bay_id(), starting_fuel(), &clock);

    let fuel = bay_fuel(&mut scenario, entity_id, fuel_bay_id());
    assert!(fuel.quantity() == 0 && fuel.fuel_type().is_none());
    assert!(stored_draw(&mut scenario, entity_id, MOD_A) == 0);
    let (_, capacity, _, _) = projected(&mut scenario, entity_id, &clock);
    assert!(capacity == 0);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = grid_fuel::EBayShort)]
fun siphon_more_than_the_bay_holds_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = siphon_ready(&mut scenario, &clock);

    siphon(
        &mut scenario,
        admin(),
        entity_id,
        FUEL_B,
        QUARTER_UNITS * power_grid::scale() + 1,
        &clock,
    );

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EZeroFuel)]
fun siphon_zero_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = siphon_ready(&mut scenario, &clock);

    siphon(&mut scenario, admin(), entity_id, FUEL_B, 0, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EFuelBayNotConnected)]
fun siphon_unknown_bay_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = siphon_ready(&mut scenario, &clock);

    siphon(&mut scenario, admin(), entity_id, 1, 10_000, &clock);

    abort
}

#[test, expected_failure(abort_code = core::admin_service::EUnauthorizedAdmin)]
fun siphon_by_non_admin_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = siphon_ready(&mut scenario, &clock);

    siphon(&mut scenario, owner(), entity_id, FUEL_B, 10_000, &clock);

    abort
}
