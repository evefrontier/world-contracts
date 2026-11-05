#[test_only]
module power::pool_tests;

use core::{entity::Entity, test_helpers::setup};
use power::{
    grid_scenario::{
        admin,
        bay_fuel,
        catch_up,
        deposit_typed,
        firm_power,
        fuel_bay_id,
        fuel_capacity,
        fuel_type,
        generator_id,
        install_fuel,
        install_generator,
        install_module,
        owner,
        power_up,
        projected,
        projected_bay_amount,
        set_desired,
        set_fuel_bay,
        setup_entity,
        starting_fuel,
        thermal,
        volatility,
        volatility_limit
    },
    power_grid::{Self, Fuel}
};
use sui::{clock::{Self, Clock}, test_scenario as ts};

const MOD_A: u64 = 401;
/// Second bay, holding `OTHER_TYPE`.
const FUEL_B: u64 = 9_002;
const OTHER_TYPE: u64 = 8;
/// 15 MW each.
const OUTPUT: u64 = 15;
/// Impulse limit 100, above both test fuels.
const IMPULSE_LIMIT: u64 = 1_000_000;
/// `OTHER_TYPE` fuel: impulse 45, 1_000 plain units.
const OTHER_IMPULSE: u64 = 450_000;
const OTHER_UNITS: u64 = 1_000;

// === Helpers ===

/// Generator 0 burns `fuel_type()` from the default bay; Generator 1 burns
/// `OTHER_TYPE` from `FUEL_B`. Both online, grid on, `MOD_A` drawing `draw` MW.
fun two_pools(scenario: &mut ts::Scenario, draw: u64, clock: &Clock): ID {
    let entity_id = setup_entity(scenario, vector[OUTPUT], vector[IMPULSE_LIMIT], clock);
    install_other_generator(scenario, entity_id, clock);
    install_fuel(scenario, entity_id, FUEL_B, fuel_capacity(), clock);
    deposit_typed(
        scenario,
        entity_id,
        FUEL_B,
        OTHER_TYPE,
        OTHER_UNITS,
        OTHER_IMPULSE,
        thermal(),
        clock,
    );
    set_fuel_bay(scenario, entity_id, FUEL_B, true, clock);
    power_up(scenario, entity_id, 2, clock);
    install_module(scenario, entity_id, MOD_A, firm_power(draw), clock);
    set_desired(scenario, entity_id, MOD_A, true, clock);
    entity_id
}

/// Generator 1, burning `OTHER_TYPE` at `OUTPUT`, offline.
fun install_other_generator(scenario: &mut ts::Scenario, entity_id: ID, clock: &Clock) {
    install_generator(
        scenario,
        entity_id,
        generator_id(1),
        OTHER_TYPE,
        vector[],
        OUTPUT,
        IMPULSE_LIMIT,
        volatility_limit(),
        clock,
    );
}

fun pool(scenario: &mut ts::Scenario, entity_id: ID, fuel_type: u64): Fuel {
    ts::next_tx(scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let fuel = power_grid::power_grid(&entity).pool_fuel(fuel_type);
    ts::return_shared(entity);
    fuel
}

fun capacity(scenario: &mut ts::Scenario, entity_id: ID, clock: &Clock): u64 {
    let (_, capacity, _, _) = projected(scenario, entity_id, clock);
    capacity
}

// === Pools ===

/// Each pool blends only the online bays of its own type.
#[test]
fun pool_reads_only_its_type() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_pools(&mut scenario, 20, &clock);

    let own = pool(&mut scenario, entity_id, fuel_type());
    assert!(own.fuel_type() == option::some(fuel_type()));
    assert!(own.quantity() == starting_fuel());
    let other = pool(&mut scenario, entity_id, OTHER_TYPE);
    assert!(other.fuel_type() == option::some(OTHER_TYPE));
    assert!(other.quantity() == OTHER_UNITS * power_grid::scale());
    assert!(other.impulse() == OTHER_IMPULSE);
    assert!(pool(&mut scenario, entity_id, 99).quantity() == 0);

    clock.destroy_for_testing();
    scenario.end();
}

/// 20 MW splits 10/10 across two 15 MW Generators. Generator 0 burns 10 MW at
/// impulse 90 (1_112 a second, rounded up) from its pool; Generator 1 burns
/// 10 MW at impulse 45 (2_223) from the other. The view matches the settle.
#[test]
fun two_pools_burn_independently() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_pools(&mut scenario, 20, &clock);

    clock.set_for_testing(1_000);
    let own_left = projected_bay_amount(&mut scenario, entity_id, fuel_bay_id(), &clock);
    let other_left = projected_bay_amount(&mut scenario, entity_id, FUEL_B, &clock);
    assert!(own_left == starting_fuel() - 1_112);
    assert!(other_left == OTHER_UNITS * power_grid::scale() - 2_223);

    catch_up(&mut scenario, entity_id, MOD_A, &clock);
    assert!(bay_fuel(&mut scenario, entity_id, fuel_bay_id()).quantity() == own_left);
    assert!(bay_fuel(&mut scenario, entity_id, FUEL_B).quantity() == other_left);

    clock.destroy_for_testing();
    scenario.end();
}

/// Output is rated × volatility share: pool volatility 1 against a limit of 2
/// gives half of 15 MW, floored to 7.
#[test]
fun output_scales_with_volatility() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    install_generator(
        &mut scenario,
        entity_id,
        generator_id(0),
        fuel_type(),
        vector[],
        OUTPUT,
        IMPULSE_LIMIT,
        2 * volatility(),
        &clock,
    );
    power_up(&mut scenario, entity_id, 1, &clock);

    assert!(capacity(&mut scenario, entity_id, &clock) == 7);

    clock.destroy_for_testing();
    scenario.end();
}

/// A Generator whose pool is empty stays online and supplies nothing, even
/// while another pool holds fuel. Fuel of its type brings it back.
#[test]
fun empty_pool_generator_stays_online_and_supplies_nothing() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    install_generator(
        &mut scenario,
        entity_id,
        generator_id(0),
        OTHER_TYPE,
        vector[],
        OUTPUT,
        IMPULSE_LIMIT,
        volatility_limit(),
        &clock,
    );
    power_up(&mut scenario, entity_id, 1, &clock);

    assert!(capacity(&mut scenario, entity_id, &clock) == 0);
    ts::next_tx(&mut scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    assert!(power_grid::generator_state(&entity, generator_id(0)).online());
    ts::return_shared(entity);

    install_fuel(&mut scenario, entity_id, FUEL_B, fuel_capacity(), &clock);
    deposit_typed(
        &mut scenario,
        entity_id,
        FUEL_B,
        OTHER_TYPE,
        OTHER_UNITS,
        OTHER_IMPULSE,
        thermal(),
        &clock,
    );
    set_fuel_bay(&mut scenario, entity_id, FUEL_B, true, &clock);
    assert!(capacity(&mut scenario, entity_id, &clock) == OUTPUT);

    clock.destroy_for_testing();
    scenario.end();
}

/// Switching a bay offline takes its fuel out of its pool, and the Generator
/// on that pool stops supplying.
#[test]
fun offline_bay_leaves_its_pool() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_pools(&mut scenario, 10, &clock);
    assert!(capacity(&mut scenario, entity_id, &clock) == 2 * OUTPUT);

    set_fuel_bay(&mut scenario, entity_id, FUEL_B, false, &clock);

    assert!(pool(&mut scenario, entity_id, OTHER_TYPE).quantity() == 0);
    assert!(capacity(&mut scenario, entity_id, &clock) == OUTPUT);
    assert!(
        bay_fuel(&mut scenario, entity_id, FUEL_B).quantity() == OTHER_UNITS * power_grid::scale(),
    );

    clock.destroy_for_testing();
    scenario.end();
}
