#[test_only]
module power::warp_tests;

use core::test_helpers::setup;
use power::{
    fuel_properties,
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
        withdraw_from_bay,
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
const IMPULSE_LIMIT: u64 = 100_000_000_000;

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

    withdraw(&mut scenario, admin(), entity_id, 10 * power_grid::scale(), &clock);

    let withdrawn = event::events_by_type<FuelWithdrawn>();
    let (_, withdrawn_type, quantity, remaining) = withdrawn[0].fuel_withdrawn_fields();
    assert!(withdrawn_type == fuel_type());
    let total = starting_fuel() + starting_fuel() / 4;
    assert!(quantity == 10 * power_grid::scale() && remaining == total - 10 * power_grid::scale());
    assert!(
        bay_fuel(&mut scenario, entity_id, fuel_bay_id()).quantity() == starting_fuel() - 8 * power_grid::scale(),
    );
    assert!(
        bay_fuel(&mut scenario, entity_id, FUEL_B).quantity() == starting_fuel() / 4 - 2 * power_grid::scale(),
    );

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

    withdraw(&mut scenario, admin(), entity_id, 10 * power_grid::scale(), &clock);

    assert!(
        bay_fuel(&mut scenario, entity_id, fuel_bay_id()).quantity() == starting_fuel() - 10 * power_grid::scale(),
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
    let entity_id = setup_entity(&mut scenario, vector[15], vector[IMPULSE_LIMIT], &clock);
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
    let entity_id = setup_entity(&mut scenario, vector[15], vector[IMPULSE_LIMIT], &clock);
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

    withdraw(&mut scenario, owner(), entity_id, 10 * power_grid::scale(), &clock);

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

    withdraw_type(&mut scenario, admin(), entity_id, OTHER_TYPE, 10 * power_grid::scale(), &clock);

    let withdrawn = event::events_by_type<FuelWithdrawn>();
    let (_, withdrawn_type, quantity, remaining) = withdrawn[0].fuel_withdrawn_fields();
    let other_held = QUARTER_UNITS * power_grid::scale();
    assert!(withdrawn_type == OTHER_TYPE && quantity == 10 * power_grid::scale());
    assert!(remaining == other_held - 10 * power_grid::scale());
    assert!(
        bay_fuel(&mut scenario, entity_id, FUEL_B).quantity() == other_held - 10 * power_grid::scale(),
    );
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
        QUARTER_UNITS * power_grid::scale() + fuel_properties::mass_step(),
        &clock,
    );

    abort
}

// === Withdraw from one bay ===

/// Only the named bay gives; the other online bay of the same type keeps its fuel.
#[test]
fun withdraw_from_bay_takes_only_that_bay() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_bays(&mut scenario, &clock);

    withdraw_from_bay(
        &mut scenario,
        admin(),
        entity_id,
        fuel_type(),
        FUEL_B,
        10 * power_grid::scale(),
        &clock,
    );

    let withdrawn = event::events_by_type<FuelWithdrawn>();
    let (_, withdrawn_type, quantity, remaining) = withdrawn[0].fuel_withdrawn_fields();
    let left = starting_fuel() / 4 - 10 * power_grid::scale();
    assert!(withdrawn_type == fuel_type() && quantity == 10 * power_grid::scale());
    assert!(remaining == starting_fuel() + left);
    assert!(withdrawn[0].fuel_withdrawn_bay_id() == option::some(FUEL_B));
    assert!(bay_fuel(&mut scenario, entity_id, FUEL_B).quantity() == left);
    assert!(bay_fuel(&mut scenario, entity_id, fuel_bay_id()).quantity() == starting_fuel());

    clock.destroy_for_testing();
    scenario.end();
}

/// A pool withdrawal reports no bay.
#[test]
fun withdraw_from_pool_reports_no_bay() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_bays(&mut scenario, &clock);

    withdraw(&mut scenario, admin(), entity_id, power_grid::scale(), &clock);

    let withdrawn = event::events_by_type<FuelWithdrawn>();
    assert!(withdrawn[0].fuel_withdrawn_bay_id().is_none());

    clock.destroy_for_testing();
    scenario.end();
}

/// Taking everything a bay holds empties it and clears its type.
#[test]
fun withdraw_from_bay_all_clears_the_type() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_bays(&mut scenario, &clock);

    withdraw_from_bay(
        &mut scenario,
        admin(),
        entity_id,
        fuel_type(),
        FUEL_B,
        starting_fuel() / 4,
        &clock,
    );

    let fuel = bay_fuel(&mut scenario, entity_id, FUEL_B);
    assert!(fuel.quantity() == 0 && fuel.fuel_type().is_none());
    assert!(bay_fuel(&mut scenario, entity_id, fuel_bay_id()).quantity() == starting_fuel());

    clock.destroy_for_testing();
    scenario.end();
}

/// The pool could cover it, but the named bay can't: nothing is taken.
#[test, expected_failure(abort_code = grid_fuel::EBayShort)]
fun withdraw_from_bay_more_than_it_holds_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_bays(&mut scenario, &clock);

    withdraw_from_bay(
        &mut scenario,
        admin(),
        entity_id,
        fuel_type(),
        FUEL_B,
        starting_fuel() / 4 + 1,
        &clock,
    );

    abort
}

/// Burn counts before the check: a bay that looks full can still be short.
#[test, expected_failure(abort_code = grid_fuel::EBayShort)]
fun withdraw_from_bay_more_than_left_after_burn_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[15], vector[IMPULSE_LIMIT], &clock);
    power_up(&mut scenario, entity_id, 1, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(10), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);
    enable_withdraw(&mut scenario, entity_id);
    clock.set_for_testing(10_000);

    withdraw_from_bay(
        &mut scenario,
        admin(),
        entity_id,
        fuel_type(),
        fuel_bay_id(),
        starting_fuel(),
        &clock,
    );

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EFuelBayNotConnected)]
fun withdraw_from_unknown_bay_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_bays(&mut scenario, &clock);

    withdraw_from_bay(
        &mut scenario,
        admin(),
        entity_id,
        fuel_type(),
        1,
        power_grid::scale(),
        &clock,
    );

    abort
}

/// An offline bay feeds nothing, so it can't be named for a warp.
#[test, expected_failure(abort_code = grid_fuel::EFuelBayOffline)]
fun withdraw_from_offline_bay_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_bays(&mut scenario, &clock);
    set_fuel_bay(&mut scenario, entity_id, FUEL_B, false, &clock);

    withdraw_from_bay(
        &mut scenario,
        admin(),
        entity_id,
        fuel_type(),
        FUEL_B,
        power_grid::scale(),
        &clock,
    );

    abort
}

/// The named bay holds another type, and less than asked: the type is reported.
#[test, expected_failure(abort_code = grid_fuel::EFuelTypeMismatch)]
fun withdraw_from_bay_of_another_type_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_types(&mut scenario, &clock);

    withdraw_from_bay(
        &mut scenario,
        admin(),
        entity_id,
        fuel_type(),
        FUEL_B,
        starting_fuel() / 4 + 1,
        &clock,
    );

    abort
}

/// An emptied bay has no type, so it is short rather than mismatched.
#[test, expected_failure(abort_code = grid_fuel::EBayShort)]
fun withdraw_from_empty_bay_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_bays(&mut scenario, &clock);
    let all = starting_fuel() / 4;
    withdraw_from_bay(&mut scenario, admin(), entity_id, fuel_type(), FUEL_B, all, &clock);

    withdraw_from_bay(
        &mut scenario,
        admin(),
        entity_id,
        fuel_type(),
        FUEL_B,
        power_grid::scale(),
        &clock,
    );

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EZeroFuel)]
fun withdraw_from_bay_zero_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_bays(&mut scenario, &clock);

    withdraw_from_bay(&mut scenario, admin(), entity_id, fuel_type(), FUEL_B, 0, &clock);

    abort
}

#[test, expected_failure(abort_code = core::admin_service::EUnauthorizedAdmin)]
fun withdraw_from_bay_by_non_admin_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_bays(&mut scenario, &clock);

    withdraw_from_bay(
        &mut scenario,
        owner(),
        entity_id,
        fuel_type(),
        FUEL_B,
        power_grid::scale(),
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

    siphon(&mut scenario, admin(), entity_id, fuel_bay_id(), 7 * power_grid::scale(), &clock);

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
    assert!(siphoned_type == fuel_type() && quantity == 7 * power_grid::scale());
    assert!(siphoned[0].fuel_siphoned_tenant() == core::test_helpers::tenant());
    assert!(siphoned[0].fuel_siphoned_unit_volume() == power::grid_scenario::unit_volume());
    assert!(siphoned_impulse == impulse() && siphoned_volatility == volatility());
    assert!(siphoned_burden == burden() && siphoned_thermal == thermal());
    let fuel = bay_fuel(&mut scenario, entity_id, fuel_bay_id());
    assert!(fuel.quantity() == starting_fuel() - 7 * power_grid::scale());
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

    siphon(&mut scenario, admin(), entity_id, FUEL_B, power_grid::scale(), &clock);

    let held = QUARTER_UNITS * power_grid::scale() - power_grid::scale();
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
        QUARTER_UNITS * power_grid::scale() + fuel_properties::mass_step(),
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

/// 0.0099 kg is a whole step but below the game's smallest stack: it could not
/// be minted back, so it never leaves the bay.
#[test, expected_failure(abort_code = fuel_properties::EBelowMinimum)]
fun siphon_below_minimum_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = siphon_ready(&mut scenario, &clock);

    siphon(
        &mut scenario,
        admin(),
        entity_id,
        FUEL_B,
        fuel_properties::min_stack() - fuel_properties::mass_step(),
        &clock,
    );

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EFuelBayNotConnected)]
fun siphon_unknown_bay_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = siphon_ready(&mut scenario, &clock);

    siphon(&mut scenario, admin(), entity_id, 1, power_grid::scale(), &clock);

    abort
}

#[test, expected_failure(abort_code = core::admin_service::EUnauthorizedAdmin)]
fun siphon_by_non_admin_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = siphon_ready(&mut scenario, &clock);

    siphon(&mut scenario, owner(), entity_id, FUEL_B, power_grid::scale(), &clock);

    abort
}
