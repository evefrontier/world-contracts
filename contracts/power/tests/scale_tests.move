/// A large grid with two pools. Run with `--statistics` and compare the two
/// tests: the gap is one settle stepping through both run-outs. Kept at `SIZE`
/// because `test_scenario` overhead, not the grid, exhausts test gas past ~30.
#[test_only]
module power::scale_tests;

use core::{entity::Entity, test_helpers::setup};
use power::{
    grid_scenario::{
        admin,
        catch_up,
        deposit_typed,
        elastic_power,
        fuel_type,
        generator_id,
        install_fuel,
        install_generator,
        install_module,
        owner,
        power,
        set_desired,
        set_fuel_bay,
        set_generator,
        setup_entity,
        thermal,
        volatility_limit
    },
    power_grid
};
use sui::{clock::{Self, Clock}, test_scenario as ts};

const OTHER_TYPE: u64 = 8;
const FIRST_BAY: u64 = 20_000;
const FIRST_MODULE: u64 = 30_000;
const BAY_CAPACITY: u64 = 10_000;
/// Impulse 90 at `SCALE`.
const IMPULSE: u64 = 900_000;
const IMPULSE_LIMIT: u64 = 1_000_000;
/// Generators, bays and modules each.
const SIZE: u64 = 20;
/// Long enough that both pools run dry, in ms.
const DEPLETING_MS: u64 = 10_000_000_000_000;

#[test]
fun full_grid_setup() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    full_grid(&mut scenario, &clock);

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun full_grid_settle_through_both_run_outs() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = full_grid(&mut scenario, &clock);

    clock.set_for_testing(DEPLETING_MS);
    catch_up(&mut scenario, entity_id, FIRST_MODULE, &clock);

    ts::next_tx(&mut scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    assert!(power_grid::projected_fuel(&entity, &clock) == 0);
    assert!(power_grid::power_grid(&entity).on());
    ts::return_shared(entity);

    clock.destroy_for_testing();
    scenario.end();
}

/// `SIZE` Generators split across two fuel types, `SIZE` online bays split the
/// same way with different amounts, and `SIZE` desired Elastic modules, so a
/// run-out never trips the grid.
fun full_grid(scenario: &mut ts::Scenario, clock: &Clock): ID {
    let entity_id = setup_entity(scenario, vector[], vector[], clock);
    power(scenario, entity_id, true, clock);
    SIZE.do!(|i| {
        let t = if (i % 2 == 0) fuel_type() else OTHER_TYPE;
        install_generator(
            scenario,
            entity_id,
            generator_id(i),
            t,
            vector[],
            10,
            IMPULSE_LIMIT,
            volatility_limit(),
            clock,
        );
        set_generator(scenario, entity_id, i, true, clock);
    });
    // The setup bay is one of the `SIZE`.
    (SIZE - 1).do!(|i| {
        let bay = FIRST_BAY + i;
        let (t, amount) = if (i % 2 == 0) (fuel_type(), 1_000) else (OTHER_TYPE, 3_000);
        install_fuel(scenario, entity_id, bay, BAY_CAPACITY, clock);
        deposit_typed(scenario, entity_id, bay, t, amount, IMPULSE, thermal(), clock);
        set_fuel_bay(scenario, entity_id, bay, true, clock);
    });
    SIZE.do!(|i| {
        install_module(scenario, entity_id, FIRST_MODULE + i, elastic_power(1), clock);
        set_desired(scenario, entity_id, FIRST_MODULE + i, true, clock);
    });
    entity_id
}
