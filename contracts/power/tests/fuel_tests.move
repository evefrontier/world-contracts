#[test_only]
module power::fuel_tests;

use core::{entity::Entity, test_helpers::setup};
use power::{
    fuel_math,
    grid_fuel::{Self, FuelAdded},
    grid_scenario::{
        Self,
        admin,
        burden,
        catch_up,
        deposit_fuel,
        deposit_fuel_via,
        draw,
        enable_owner_in_handler,
        firm_power,
        fuel_capacity,
        fuel_id,
        fuel_type,
        impulse,
        install_fuel,
        install_module,
        owner,
        power_up,
        projected,
        set_desired,
        setup_entity,
        settled_fuel,
        starting_fuel,
        uninstall_fuel
    },
    power_grid
};
use sui::{clock::{Self, Clock}, event, test_scenario as ts};

const FUEL_B: u64 = 9_002;
const MOD_A: u64 = 401;
/// 15 MW at `SCALE`.
const OUTPUT: u64 = 150_000;
/// 10 MW at `SCALE`.
const DRAW: u64 = 100_000;
/// Containment reduction 10 at `SCALE`.
const CONTAINMENT: u64 = 100_000;
const GATED_DEPOSIT: vector<u8> = b"gated_deposit";
const OTHER_TYPE: u64 = 8;
const BANNED_TYPE: u64 = 9;

// === Helpers ===

/// One online Generator of `OUTPUT`, grid on, `MOD_A` desired and drawing `DRAW`.
fun loaded(scenario: &mut ts::Scenario, clock: &Clock): ID {
    let entity_id = setup_entity(scenario, vector[OUTPUT], vector[CONTAINMENT], clock);
    power_up(scenario, entity_id, 1, clock);
    install_module(scenario, entity_id, MOD_A, firm_power(DRAW), clock);
    set_desired(scenario, entity_id, MOD_A, true, clock);
    entity_id
}

/// `(capacity, impulse, containment_burden)` of the grid.
fun fuel_stats(scenario: &mut ts::Scenario, entity_id: ID): (u64, u64, u64) {
    ts::next_tx(scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let grid = power_grid::power_grid(&entity);
    let capacity = grid.fuel_capacity();
    let impulse = grid.fuel_impulse();
    let burden = grid.fuel_containment_burden();
    ts::return_shared(entity);
    (capacity, impulse, burden)
}

/// A grid whose owner action `GATED_DEPOSIT` accepts fuel types `fuel_type()` and
/// `OTHER_TYPE`, impulse >= 0.5, burden <= 15, and 0.1 to 1_000 units per deposit.
fun gated_deposit(scenario: &mut ts::Scenario, clock: &Clock): ID {
    let entity_id = setup_entity(scenario, vector[], vector[], clock);
    enable_owner_in_handler(
        scenario,
        entity_id,
        GATED_DEPOSIT,
        power_grid::deposit_fuel_requirement(
            vector[fuel_type(), OTHER_TYPE],
            option::some(500_000),
            option::some(150_000),
            option::some(1_000),
            option::some(10_000_000),
        ),
    );
    entity_id
}

// === Fuel factor ===

#[test]
fun fuel_factor_matches_client() {
    // impulse 90, burden 14, reduction 10 -> 90 / 1.4 = 64.2857
    assert!(fuel_math::fuel_factor(900_000, 140_000, 100_000) == 642_857);
    // impulse 10, burden 3, reduction 10 -> burden ratio floors at 1 -> 10
    assert!(fuel_math::fuel_factor(100_000, 30_000, 100_000) == 100_000);
    // impulse 0.4 clamps up to 1
    assert!(fuel_math::fuel_factor(4_000, 30_000, 100_000) == 10_000);
    // impulse 200 clamps down to 100
    assert!(fuel_math::fuel_factor(2_000_000, 30_000, 100_000) == 1_000_000);
    // reduction 0 floors at 1 -> 90 / 14 = 6.4285
    assert!(fuel_math::fuel_factor(900_000, 140_000, 0) == 64_285);
}

// === Fuel sources ===

#[test]
fun install_fuel_source_adds_capacity() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    install_fuel(&mut scenario, entity_id, FUEL_B, 1_000, &clock);

    let (capacity, _, _) = fuel_stats(&mut scenario, entity_id);
    assert!(capacity == fuel_capacity() + 1_000);
    ts::next_tx(&mut scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    assert!(power_grid::is_fuel_source_connected(&entity, FUEL_B));
    assert!(power_grid::power_grid(&entity).fuel_source_capacity(FUEL_B) == 1_000);
    ts::return_shared(entity);

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun uninstall_fuel_source_removes_capacity() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    install_fuel(&mut scenario, entity_id, FUEL_B, 1_000, &clock);
    uninstall_fuel(&mut scenario, entity_id, FUEL_B, &clock);

    let (capacity, _, _) = fuel_stats(&mut scenario, entity_id);
    assert!(capacity == fuel_capacity());

    clock.destroy_for_testing();
    scenario.end();
}

/// Removing the only source would leave the stored fuel with no capacity.
#[test, expected_failure(abort_code = grid_fuel::EFuelOverCapacity)]
fun uninstall_aborts_when_fuel_exceeds_remaining_capacity() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    uninstall_fuel(&mut scenario, entity_id, fuel_id(), &clock);

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EFuelSourceNotConnected)]
fun uninstall_unknown_fuel_source_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    uninstall_fuel(&mut scenario, entity_id, FUEL_B, &clock);

    abort
}

// === Deposit ===

/// Equal quantities average the stats: impulse (90 + 10) / 2, burden (14 + 4) / 2.
#[test]
fun deposit_blends_by_weighted_average() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    deposit_fuel(&mut scenario, entity_id, starting_fuel(), 100_000, 40_000, &clock);

    let added = event::events_by_type<FuelAdded>();
    assert!(added.length() == 1);
    let (_, _, amount, quantity, impulse, burden) = added[0].fuel_added_fields();
    assert!(amount == starting_fuel());
    assert!(quantity == 2 * starting_fuel());
    assert!(impulse == 500_000);
    assert!(burden == 90_000);
    assert!(settled_fuel(&mut scenario, entity_id) == 2 * starting_fuel());

    clock.destroy_for_testing();
    scenario.end();
}

/// A tiny deposit pulls the average down by less than one fixed-point step:
/// the blend rounds down.
#[test]
fun deposit_blend_rounds_down() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    deposit_fuel(&mut scenario, entity_id, 3, 10_000, 140_000, &clock);

    let (_, impulse, burden) = fuel_stats(&mut scenario, entity_id);
    assert!(impulse == 899_999);
    assert!(burden == 140_000);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = grid_fuel::EFuelOverCapacity)]
fun deposit_over_capacity_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    deposit_fuel(&mut scenario, entity_id, fuel_capacity(), impulse(), burden(), &clock);

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EZeroFuel)]
fun deposit_zero_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    deposit_fuel(&mut scenario, entity_id, 0, impulse(), burden(), &clock);

    abort
}

#[test]
fun deposit_meeting_fuel_requirement_succeeds() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = gated_deposit(&mut scenario, &clock);
    deposit_fuel_via(
        &mut scenario,
        entity_id,
        GATED_DEPOSIT,
        fuel_type(),
        5_000,
        600_000,
        100_000,
        &clock,
    );
    assert!(settled_fuel(&mut scenario, entity_id) == starting_fuel() + 5_000);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = grid_fuel::EFuelTypeNotAllowed)]
fun deposit_disallowed_fuel_type_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = gated_deposit(&mut scenario, &clock);
    deposit_fuel_via(
        &mut scenario,
        entity_id,
        GATED_DEPOSIT,
        BANNED_TYPE,
        5_000,
        600_000,
        100_000,
        &clock,
    );

    abort
}

#[test, expected_failure(abort_code = power_grid::EImpulseBelowMin)]
fun deposit_low_impulse_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = gated_deposit(&mut scenario, &clock);
    deposit_fuel_via(
        &mut scenario,
        entity_id,
        GATED_DEPOSIT,
        fuel_type(),
        5_000,
        400_000,
        100_000,
        &clock,
    );

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EBurdenAboveMax)]
fun deposit_high_burden_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = gated_deposit(&mut scenario, &clock);
    deposit_fuel_via(
        &mut scenario,
        entity_id,
        GATED_DEPOSIT,
        fuel_type(),
        5_000,
        600_000,
        200_000,
        &clock,
    );

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EFuelAmountBelowMin)]
fun deposit_below_min_amount_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = gated_deposit(&mut scenario, &clock);
    deposit_fuel_via(
        &mut scenario,
        entity_id,
        GATED_DEPOSIT,
        fuel_type(),
        500,
        600_000,
        100_000,
        &clock,
    );

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EFuelAmountAboveMax)]
fun deposit_above_max_amount_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = gated_deposit(&mut scenario, &clock);
    deposit_fuel_via(
        &mut scenario,
        entity_id,
        GATED_DEPOSIT,
        fuel_type(),
        20_000_000,
        600_000,
        100_000,
        &clock,
    );

    abort
}

// === Burn ===

/// 10 MW at factor 64.2857 burns 0.15556 units/s: 15_556 at `SCALE` over 10 s,
/// rounded up. The view matches the state after the next settle.
#[test]
fun burn_over_time_and_view_matches_settle() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = loaded(&mut scenario, &clock);

    clock.set_for_testing(10_000);
    let (fuel_left, capacity, used_mw, online) = projected(&mut scenario, entity_id, &clock);
    assert!(fuel_left == starting_fuel() - 15_556);
    assert!(capacity == OUTPUT);
    assert!(used_mw == DRAW);
    assert!(online == vector[MOD_A]);
    assert!(settled_fuel(&mut scenario, entity_id) == starting_fuel());

    catch_up(&mut scenario, entity_id, MOD_A, &clock);
    assert!(settled_fuel(&mut scenario, entity_id) == fuel_left);

    clock.destroy_for_testing();
    scenario.end();
}

/// Stored fuel still shows the full tank. The check must burn first, then fail.
#[test, expected_failure(abort_code = power_grid::EFuelBelowMin)]
fun assert_power_grid_rejects_fuel_already_burned() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = loaded(&mut scenario, &clock);

    clock.set_for_testing(10_000);
    assert!(settled_fuel(&mut scenario, entity_id) == starting_fuel());
    grid_scenario::temp_action!(
        &mut scenario,
        entity_id,
        power_grid::power_grid_requirement(
            true,
            option::some(starting_fuel()),
            option::none(),
            0,
            option::none(),
        ),
        |entity, req| power_grid::assert_power_grid(entity, req, &clock),
    );

    abort
}

/// impulse 90, burden 14, 120 MW of 150 MW. Gen A (100 MW, reduction 10) serves
/// 80 MW at factor 64.2857; Gen B (50 MW, reduction 1) serves 40 MW at factor
/// 6.4285. 12_445 + 62_223 per second at `SCALE`.
#[test]
fun each_generator_burns_its_share() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(
        &mut scenario,
        vector[1_000_000, 500_000],
        vector[100_000, 10_000],
        &clock,
    );
    power_up(&mut scenario, entity_id, 2, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(1_200_000), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);

    clock.set_for_testing(1_000);
    catch_up(&mut scenario, entity_id, MOD_A, &clock);
    assert!(settled_fuel(&mut scenario, entity_id) == starting_fuel() - (12_445 + 62_223));

    clock.destroy_for_testing();
    scenario.end();
}

/// Ten 100 ms settles burn 10 × 156; one 1 s settle burns 1_556. Rounding up
/// costs at most one step per settle and never gives free power.
#[test]
fun frequent_settles_never_burn_less() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = loaded(&mut scenario, &clock);

    10u64.do!(|i| {
        clock.set_for_testing((i + 1) * 100);
        catch_up(&mut scenario, entity_id, MOD_A, &clock);
    });
    let frequent = starting_fuel() - settled_fuel(&mut scenario, entity_id);
    assert!(frequent == 1_560);

    clock.set_for_testing(2_000);
    catch_up(&mut scenario, entity_id, MOD_A, &clock);
    let once = starting_fuel() - frequent - settled_fuel(&mut scenario, entity_id);
    assert!(once == 1_556);

    clock.destroy_for_testing();
    scenario.end();
}

/// No load, no burn: an idle powered grid keeps its fuel.
#[test]
fun idle_grid_burns_nothing() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[OUTPUT], vector[CONTAINMENT], &clock);
    power_up(&mut scenario, entity_id, 1, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);

    clock.set_for_testing(1_000_000);
    catch_up(&mut scenario, entity_id, MOD_A, &clock);
    assert!(settled_fuel(&mut scenario, entity_id) == starting_fuel());
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == 0);

    clock.destroy_for_testing();
    scenario.end();
}
