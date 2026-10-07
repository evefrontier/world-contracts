#[test_only]
module power::fuel_tests;

use core::{
    access_cap::{Self, AccessCap},
    admin_service,
    entity::Entity,
    test_helpers::{setup, take_acl}
};
use power::{
    fuel,
    grid_scenario::{
        connect,
        deposit_fuel,
        deposit_fuel_via,
        enable,
        fuel_capacity,
        fuel_id,
        fuel_type,
        has_reservation,
        install_fuel,
        owner,
        power,
        power_up,
        register_fuel_source,
        register_fuel_source_as,
        reserve_firm,
        set_priority,
        settled_fuel,
        setup_entity,
        setup_entity_with_containments,
        starting_fuel,
        unregister_fuel_source,
        used
    },
    power_grid::{Self, FuelAdded, FuelDepleted, Shed}
};
use std::string;
use sui::{clock::{Self, Clock}, event, test_scenario as ts};

const ADMIN: address = @0xA;
const MOD_A: u64 = 401;
const FUEL_B: u64 = 9_002;
/// 15 MW at `SCALE`.
const OUTPUT: u64 = 150_000;
/// 10 MW at `SCALE`.
const DRAW: u64 = 100_000;
const GATED_DEPOSIT: vector<u8> = b"gated_deposit";
const OTHER_TYPE: u64 = 8;
const BANNED_TYPE: u64 = 9;

// === Helpers ===

/// One online Generator of `OUTPUT`, grid on, `MOD_A` holding a firm `DRAW`.
fun loaded(scenario: &mut ts::Scenario, clock: &Clock): ID {
    let entity_id = setup_entity(scenario, vector[OUTPUT], vector[MOD_A], clock);
    power_up(scenario, entity_id, 1, clock);
    connect(scenario, entity_id, MOD_A, 0, 0, clock);
    reserve_firm(scenario, entity_id, MOD_A, DRAW, clock);
    entity_id
}

/// A mutating no-op that settles the grid.
fun simulate_catchup(scenario: &mut ts::Scenario, entity_id: ID, clock: &Clock) {
    set_priority(scenario, entity_id, MOD_A, 0, clock);
}

/// `(projected_fuel, effective_capacity_mw, used_mw, reserved)` at `clock`.
fun projected(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    clock: &Clock,
): (u64, u64, u64, vector<u64>) {
    ts::next_tx(scenario, owner());
    let e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let grid = power_grid::power_grid(&e);
    let fuel_left = grid.projected_fuel(clock);
    let (capacity, used_mw, reserved) = grid.projected_status(clock);
    ts::return_shared(e);
    (fuel_left, capacity, used_mw, reserved)
}

/// `(fuel_capacity, fuel_impulse, fuel_containment_burden)`.
fun fuel_stats(scenario: &mut ts::Scenario, entity_id: ID): (u64, u64, u64) {
    ts::next_tx(scenario, owner());
    let e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let grid = power_grid::power_grid(&e);
    let (capacity, impulse, burden) = (
        grid.fuel_capacity(),
        grid.fuel_impulse(),
        grid.fuel_containment_burden(),
    );
    ts::return_shared(e);
    (capacity, impulse, burden)
}

/// A grid whose owner action `GATED_DEPOSIT` accepts fuel types `fuel_type()` and
/// `OTHER_TYPE`, impulse >= 50, burden <= 15, and 0.1 to 1_000 units per deposit.
fun gated_deposit(scenario: &mut ts::Scenario, clock: &Clock): ID {
    let entity_id = setup_entity(scenario, vector[], vector[], clock);
    enable(
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
    assert!(power_grid::fuel_factor(900_000, 140_000, 100_000) == 642_857);
    // impulse 10, burden 3, reduction 10 -> burden ratio floors at 1 -> 10
    assert!(power_grid::fuel_factor(100_000, 30_000, 100_000) == 100_000);
    // impulse 0.4 clamps up to 1
    assert!(power_grid::fuel_factor(4_000, 30_000, 100_000) == 10_000);
    // impulse 200 clamps down to 100
    assert!(power_grid::fuel_factor(2_000_000, 30_000, 100_000) == 1_000_000);
    // reduction 0 floors at 1 -> 90 / 14 = 6.4285
    assert!(power_grid::fuel_factor(900_000, 140_000, 0) == 64_285);
}

// === Fuel sources ===

#[test]
fun register_fuel_source_adds_capacity() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    install_fuel(&mut scenario, entity_id, FUEL_B);
    register_fuel_source(&mut scenario, entity_id, FUEL_B, 1_000, &clock);

    let (capacity, _, _) = fuel_stats(&mut scenario, entity_id);
    assert!(capacity == fuel_capacity() + 1_000);
    ts::next_tx(&mut scenario, ADMIN);
    let e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    assert!(power_grid::is_fuel_source_registered(&e, FUEL_B));
    assert!(power_grid::power_grid(&e).fuel_source_capacity(FUEL_B) == 1_000);
    ts::return_shared(e);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = fuel::EComponentMissing)]
fun register_missing_fuel_source_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    register_fuel_source(&mut scenario, entity_id, FUEL_B, 1_000, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::EFuelSourceAlreadyRegistered)]
fun register_fuel_source_twice_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    register_fuel_source(&mut scenario, entity_id, fuel_id(), 1_000, &clock);

    abort
}

#[test, expected_failure(abort_code = admin_service::EUnauthorizedAdmin)]
fun register_fuel_source_by_non_admin_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    install_fuel(&mut scenario, entity_id, FUEL_B);
    register_fuel_source_as(&mut scenario, owner(), entity_id, FUEL_B, 1_000, &clock);

    abort
}

#[test]
fun unregister_and_uninstall_fuel_source() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    install_fuel(&mut scenario, entity_id, FUEL_B);
    register_fuel_source(&mut scenario, entity_id, FUEL_B, 1_000, &clock);
    unregister_fuel_source(&mut scenario, entity_id, FUEL_B, &clock);

    let (capacity, _, _) = fuel_stats(&mut scenario, entity_id);
    assert!(capacity == fuel_capacity());
    ts::next_tx(&mut scenario, ADMIN);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    let acl = core::test_helpers::take_acl(&scenario);
    let mut req = power_grid::uninstall_fuel_source(&mut e, FUEL_B, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    assert!(!e.has_component(FUEL_B));
    ts::return_shared(acl);
    ts::return_shared(e);

    clock.destroy_for_testing();
    scenario.end();
}

/// Removing the only source would leave the stored fuel with no capacity.
#[test, expected_failure(abort_code = power_grid::EFuelOverCapacity)]
fun unregister_aborts_when_fuel_exceeds_reduced_capacity() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    unregister_fuel_source(&mut scenario, entity_id, fuel_id(), &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::EFuelSourceNotRegistered)]
fun unregister_unknown_fuel_source_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    unregister_fuel_source(&mut scenario, entity_id, FUEL_B, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::EFuelSourceStillRegistered)]
fun uninstall_registered_fuel_source_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    ts::next_tx(&mut scenario, ADMIN);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    let _req = power_grid::uninstall_fuel_source(&mut e, fuel_id(), scenario.ctx());

    abort
}

// === Deposit ===

/// Equal quantities average the stats: impulse (90 + 10) / 2, burden (14 + 4) / 2.
#[test]
fun deposit_blends_by_weighted_average() {
    let mut scenario = ts::begin(ADMIN);
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
    let mut scenario = ts::begin(ADMIN);
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

#[test, expected_failure(abort_code = power_grid::EFuelOverCapacity)]
fun deposit_over_capacity_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    deposit_fuel(&mut scenario, entity_id, fuel_capacity(), 900_000, 140_000, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::EZeroFuel)]
fun deposit_zero_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    deposit_fuel(&mut scenario, entity_id, 0, 900_000, 140_000, &clock);

    abort
}

// === Burn ===

/// 10 MW at factor 64.2857 burns 0.15556 units/s: 15_556 at `SCALE` over 10 s,
/// rounded up. The view matches the state after the next settle.
#[test]
fun burn_over_time_and_view_matches_settle() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = loaded(&mut scenario, &clock);

    clock.set_for_testing(10_000);
    let (fuel_left, capacity, used_mw, reserved) = projected(&mut scenario, entity_id, &clock);
    assert!(fuel_left == starting_fuel() - 15_556);
    assert!(capacity == OUTPUT);
    assert!(used_mw == DRAW);
    assert!(reserved == vector[MOD_A]);
    assert!(settled_fuel(&mut scenario, entity_id) == starting_fuel());

    simulate_catchup(&mut scenario, entity_id, &clock);
    assert!(settled_fuel(&mut scenario, entity_id) == fuel_left);

    clock.destroy_for_testing();
    scenario.end();
}

/// impulse 90, burden 14, 120 MW of 150 MW. Gen A (100 MW,
/// reduction 10) serves 80 MW at factor 64.2857; Gen B (50 MW, reduction 1)
/// serves 40 MW at factor 6.4285. 12_445 + 62_223 per second at `SCALE`.
#[test]
fun each_generator_burns_its_share() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity_with_containments(
        &mut scenario,
        vector[1_000_000, 500_000],
        vector[100_000, 10_000],
        vector[MOD_A],
        &clock,
    );
    power_up(&mut scenario, entity_id, 2, &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 1_200_000, &clock);

    clock.set_for_testing(1_000);
    simulate_catchup(&mut scenario, entity_id, &clock);
    assert!(settled_fuel(&mut scenario, entity_id) == starting_fuel() - (12_445 + 62_223));

    clock.destroy_for_testing();
    scenario.end();
}

/// Ten 100 ms settles burn 10 × 156; one 1 s settle burns 1_556. Rounding up
/// costs at most one step per settle and never gives free power.
#[test]
fun frequent_settles_never_burn_less() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = loaded(&mut scenario, &clock);

    10u64.do!(|i| {
        clock.set_for_testing((i + 1) * 100);
        simulate_catchup(&mut scenario, entity_id, &clock);
    });
    let frequent = starting_fuel() - settled_fuel(&mut scenario, entity_id);
    assert!(frequent == 1_560);

    clock.set_for_testing(2_000);
    simulate_catchup(&mut scenario, entity_id, &clock);
    let once = starting_fuel() - frequent - settled_fuel(&mut scenario, entity_id);
    assert!(once == 1_556);

    clock.destroy_for_testing();
    scenario.end();
}

/// No load, no burn: an idle powered grid keeps its fuel.
#[test]
fun idle_grid_burns_nothing() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[OUTPUT], vector[MOD_A], &clock);
    power_up(&mut scenario, entity_id, 1, &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);

    clock.set_for_testing(1_000_000);
    simulate_catchup(&mut scenario, entity_id, &clock);
    assert!(settled_fuel(&mut scenario, entity_id) == starting_fuel());

    clock.destroy_for_testing();
    scenario.end();
}

/// Fuel runs out between transactions: the view reads as shed at once; the
/// stored state sheds on the next transaction.
#[test]
fun depletion_sheds_on_next_transaction() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = loaded(&mut scenario, &clock);

    // 50_000 units at 0.15556 units/s last about 321_429 s.
    clock.set_for_testing(400_000_000);
    let (fuel_left, capacity, used_mw, reserved) = projected(&mut scenario, entity_id, &clock);
    assert!(fuel_left == 0 && capacity == 0 && used_mw == 0 && reserved.is_empty());
    assert!(has_reservation(&mut scenario, entity_id, MOD_A));

    simulate_catchup(&mut scenario, entity_id, &clock);
    assert!(event::events_by_type<FuelDepleted>().length() == 1);
    assert!(event::events_by_type<Shed>().length() == 1);
    assert!(settled_fuel(&mut scenario, entity_id) == 0);
    assert!(used(&mut scenario, entity_id) == 0);
    assert!(!has_reservation(&mut scenario, entity_id, MOD_A));

    clock.destroy_for_testing();
    scenario.end();
}

/// Refuelling an empty pool takes the new fuel's stats and grants nothing by
/// itself; the module reserves again.
#[test]
fun refuel_then_reserve_again() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = loaded(&mut scenario, &clock);
    clock.set_for_testing(400_000_000);
    simulate_catchup(&mut scenario, entity_id, &clock);

    deposit_fuel(&mut scenario, entity_id, 1_000_000, 300_000, 50_000, &clock);
    let (_, impulse, burden) = fuel_stats(&mut scenario, entity_id);
    assert!(impulse == 300_000 && burden == 50_000);
    assert!(!has_reservation(&mut scenario, entity_id, MOD_A));

    reserve_firm(&mut scenario, entity_id, MOD_A, DRAW, &clock);
    assert!(used(&mut scenario, entity_id) == DRAW);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = power_grid::EInsufficientPower)]
fun reserve_after_depletion_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = loaded(&mut scenario, &clock);
    clock.set_for_testing(400_000_000);
    simulate_catchup(&mut scenario, entity_id, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, DRAW, &clock);

    abort
}

/// Power off sheds everything, so nothing burns while off.
#[test]
fun powered_off_grid_burns_nothing() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = loaded(&mut scenario, &clock);
    power(&mut scenario, entity_id, false, &clock);

    clock.set_for_testing(1_000_000);
    simulate_catchup(&mut scenario, entity_id, &clock);
    assert!(settled_fuel(&mut scenario, entity_id) == starting_fuel());

    clock.destroy_for_testing();
    scenario.end();
}

// === Fuel requirement ===

#[test]
fun deposit_meeting_fuel_requirement_succeeds() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = gated_deposit(&mut scenario, &clock);
    deposit_fuel_via(
        &mut scenario,
        entity_id,
        GATED_DEPOSIT,
        OTHER_TYPE,
        1_000,
        500_000,
        150_000,
        &clock,
    );
    assert!(event::events_by_type<FuelAdded>().length() == 1);
    assert!(settled_fuel(&mut scenario, entity_id) == starting_fuel() + 1_000);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = power_grid::EFuelTypeNotAllowed)]
fun deposit_disallowed_fuel_type_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = gated_deposit(&mut scenario, &clock);
    deposit_fuel_via(
        &mut scenario,
        entity_id,
        GATED_DEPOSIT,
        BANNED_TYPE,
        1_000,
        900_000,
        140_000,
        &clock,
    );

    abort
}

#[test, expected_failure(abort_code = power_grid::EImpulseBelowMin)]
fun deposit_low_impulse_fuel_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = gated_deposit(&mut scenario, &clock);
    deposit_fuel_via(
        &mut scenario,
        entity_id,
        GATED_DEPOSIT,
        fuel_type(),
        1_000,
        499_999,
        140_000,
        &clock,
    );

    abort
}

#[test, expected_failure(abort_code = power_grid::EBurdenAboveMax)]
fun deposit_high_burden_fuel_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = gated_deposit(&mut scenario, &clock);
    deposit_fuel_via(
        &mut scenario,
        entity_id,
        GATED_DEPOSIT,
        fuel_type(),
        1_000,
        900_000,
        150_001,
        &clock,
    );

    abort
}

#[test, expected_failure(abort_code = power_grid::EFuelAmountBelowMin)]
fun deposit_below_min_amount_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = gated_deposit(&mut scenario, &clock);
    deposit_fuel_via(
        &mut scenario,
        entity_id,
        GATED_DEPOSIT,
        fuel_type(),
        999,
        900_000,
        140_000,
        &clock,
    );

    abort
}

#[test, expected_failure(abort_code = power_grid::EFuelAmountAboveMax)]
fun deposit_above_max_amount_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = gated_deposit(&mut scenario, &clock);
    deposit_fuel_via(
        &mut scenario,
        entity_id,
        GATED_DEPOSIT,
        fuel_type(),
        10_000_001,
        900_000,
        140_000,
        &clock,
    );

    abort
}

/// Without a gas sponsor on `AdminACL`, the owner alone cannot bridge fuel in.
#[test, expected_failure(abort_code = admin_service::EUnauthorizedSponsor)]
fun deposit_without_sponsor_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = gated_deposit(&mut scenario, &clock);

    // Fresh context: `next_tx` would keep the sponsor from the setup deposit.
    let epoch = scenario.ctx().epoch();
    let timestamp = scenario.ctx().epoch_timestamp_ms();
    let rgp = scenario.ctx().reference_gas_price();
    let builder = ts::ctx_builder_from_sender(owner())
        .set_epoch(epoch)
        .set_epoch_timestamp(timestamp)
        .set_reference_gas_price(rgp);
    ts::next_with_context(&mut scenario, builder);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let acl = take_acl(&scenario);
    let mut req = e.interact(string::utf8(GATED_DEPOSIT), scenario.ctx());
    access_cap::verify(&mut req, &cap);
    power_grid::deposit_fuel(&mut e, &mut req, fuel_type(), 1_000, 900_000, 140_000, &clock);
    admin_service::verify_sponsor(&mut req, &acl, scenario.ctx());

    abort
}
