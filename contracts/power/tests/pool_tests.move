#[test_only]
module power::pool_tests;

use core::{entity::Entity, test_helpers::setup};
use power::{
    grid_scenario::{
        Self,
        admin,
        bay_fuel,
        catch_up,
        draw,
        deposit_typed,
        firm_power,
        fuel_bay_id,
        fuel_capacity,
        fuel_type,
        generator_id,
        install_fuel,
        install_generator,
        install_module,
        mw,
        owner,
        power_up,
        projected,
        projected_bay_amount,
        set_desired,
        set_fuel_bay,
        setup_entity,
        starting_fuel,
        stored_draw,
        thermal,
        volatility,
        volatility_limit
    },
    power_grid::{Self, DrawChanged, Fuel, PoolView, PowerStatus}
};
use sui::{clock::{Self, Clock}, event, test_scenario as ts, vec_map::VecMap};

const MOD_A: u64 = 401;
/// Second bay, holding `OTHER_TYPE`.
const FUEL_B: u64 = 9_002;
const OTHER_TYPE: u64 = 8;
/// Third bay, holding the default type beside the default bay.
const FUEL_C: u64 = 9_003;
/// 15 MW each, at `SCALE`.
const OUTPUT: u64 = 15_000_000_000;
/// Impulse limit 100, above both test fuels.
const IMPULSE_LIMIT: u64 = 100_000_000_000;
/// `OTHER_TYPE` fuel: impulse 45, 1_000 kg.
const OTHER_IMPULSE: u64 = 45_000_000_000;
const OTHER_UNITS: u64 = 1_000;

// === Helpers ===

/// Generator 0 burns `fuel_type()` from the default bay; Generator 1 burns
/// `OTHER_TYPE` from `FUEL_B`. Both online, grid on, `MOD_A` drawing `draw` MW at `SCALE`.
fun two_pools(scenario: &mut ts::Scenario, draw: u64, clock: &Clock): ID {
    two_pools_holding(scenario, draw, OTHER_UNITS, clock)
}

/// `two_pools` with `other_units` kg in the `OTHER_TYPE` pool.
fun two_pools_holding(scenario: &mut ts::Scenario, draw: u64, other_units: u64, clock: &Clock): ID {
    let entity_id = setup_entity(scenario, vector[OUTPUT], vector[IMPULSE_LIMIT], clock);
    install_other_generator(scenario, entity_id, clock);
    install_fuel(scenario, entity_id, FUEL_B, fuel_capacity(), clock);
    deposit_typed(
        scenario,
        entity_id,
        FUEL_B,
        OTHER_TYPE,
        other_units,
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
    let entity_id = two_pools(&mut scenario, mw(20), &clock);

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
/// impulse 90 (111_111_112 a second, rounded up) from its pool; Generator 1 burns
/// 10 MW at impulse 45 (222_222_223) from the other. The view matches the settle.
#[test]
fun two_pools_burn_independently() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_pools(&mut scenario, mw(20), &clock);

    clock.set_for_testing(1_000);
    let own_left = projected_bay_amount(&mut scenario, entity_id, fuel_bay_id(), &clock);
    let other_left = projected_bay_amount(&mut scenario, entity_id, FUEL_B, &clock);
    assert!(own_left == starting_fuel() - 111_111_112);
    assert!(other_left == OTHER_UNITS * power_grid::scale() - 222_222_223);

    catch_up(&mut scenario, entity_id, MOD_A, &clock);
    assert!(bay_fuel(&mut scenario, entity_id, fuel_bay_id()).quantity() == own_left);
    assert!(bay_fuel(&mut scenario, entity_id, FUEL_B).quantity() == other_left);

    clock.destroy_for_testing();
    scenario.end();
}

/// Output is rated × volatility share: pool volatility 1 against a limit of 2
/// gives half of 15 MW: 7.5 MW, the fraction kept.
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

    assert!(capacity(&mut scenario, entity_id, &clock) == 7_500_000_000);

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
    let entity_id = two_pools(&mut scenario, mw(10), &clock);
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

// === Run-out ===

/// 20 MW Firm across two 15 MW Generators. The 1-unit `OTHER_TYPE` pool burns
/// 222_222.2 a ms and runs dry at 4.5 s; the default pool has burned 500_000_000 by
/// then. Capacity drops to 15 MW, the Firm load no longer fits, and nothing
/// draws or burns after. The view at 10 s matches the settle, which emits the
/// drop once.
#[test]
fun run_out_overloads_at_that_moment() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_pools_holding(&mut scenario, mw(20), 1, &clock);

    clock.set_for_testing(10_000);
    let (_, capacity, used, online) = projected(&mut scenario, entity_id, &clock);
    assert!(capacity == 0 && used == 0 && online.is_empty());
    let own_left = projected_bay_amount(&mut scenario, entity_id, fuel_bay_id(), &clock);
    assert!(own_left == starting_fuel() - 500_000_000);
    assert!(projected_bay_amount(&mut scenario, entity_id, FUEL_B, &clock) == 0);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == 0);

    catch_up(&mut scenario, entity_id, MOD_A, &clock);
    let changed = event::events_by_type<DrawChanged>();
    assert!(changed.length() == 1);
    assert!(bay_fuel(&mut scenario, entity_id, fuel_bay_id()).quantity() == own_left);
    let other = bay_fuel(&mut scenario, entity_id, FUEL_B);
    assert!(other.quantity() == 0 && other.fuel_type().is_none());
    assert!(stored_draw(&mut scenario, entity_id, MOD_A) == 0);

    clock.destroy_for_testing();
    scenario.end();
}

/// 10 MW Firm across two 15 MW Generators, 5 MW each. The 1-unit `OTHER_TYPE`
/// pool runs dry at 9 s, when the default pool has burned 500_000_000. The default
/// Generator then serves all 10 MW, burning 111_111_112 more over the last second:
/// 611_111_112 in all, not the 555_555_556 a single stretch would give.
#[test]
fun other_pool_burns_at_the_new_rate_after_a_run_out() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_pools_holding(&mut scenario, mw(10), 1, &clock);

    clock.set_for_testing(10_000);
    let (_, capacity, used, online) = projected(&mut scenario, entity_id, &clock);
    assert!(capacity == OUTPUT && used == mw(10) && online == vector[MOD_A]);
    let own_left = projected_bay_amount(&mut scenario, entity_id, fuel_bay_id(), &clock);
    assert!(own_left == starting_fuel() - 611_111_112);

    catch_up(&mut scenario, entity_id, MOD_A, &clock);
    assert!(event::events_by_type<DrawChanged>().is_empty());
    assert!(bay_fuel(&mut scenario, entity_id, fuel_bay_id()).quantity() == own_left);
    assert!(bay_fuel(&mut scenario, entity_id, FUEL_B).quantity() == 0);

    clock.destroy_for_testing();
    scenario.end();
}

/// A read before the run-out still burns both pools at the shared rate.
#[test]
fun read_before_run_out_uses_one_stretch() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_pools_holding(&mut scenario, mw(10), 1, &clock);

    clock.set_for_testing(4_000);
    let own_left = projected_bay_amount(&mut scenario, entity_id, fuel_bay_id(), &clock);
    let other_left = projected_bay_amount(&mut scenario, entity_id, FUEL_B, &clock);
    assert!(own_left == starting_fuel() - 222_222_223);
    assert!(other_left == power_grid::scale() - 444_444_445);

    clock.destroy_for_testing();
    scenario.end();
}

// === Pool reads ===

fun pools(scenario: &mut ts::Scenario, entity_id: ID, clock: &Clock): VecMap<u64, PoolView> {
    ts::next_tx(scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let pools = power_grid::projected_pools(&entity, clock);
    ts::return_shared(entity);
    pools
}

fun generator_status(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    index: u64,
    clock: &Clock,
): PowerStatus {
    ts::next_tx(scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let status = power_grid::generator_status(&entity, generator_id(index), clock);
    ts::return_shared(entity);
    status
}

fun module_status(scenario: &mut ts::Scenario, entity_id: ID, clock: &Clock): PowerStatus {
    ts::next_tx(scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let status = power_grid::module_status(&entity, MOD_A, clock);
    ts::return_shared(entity);
    status
}

/// Each pool reads its fuel and run-out. The 1-unit pool runs dry at 9 s; the
/// default pool then carries all 10 MW at 111_111.1 a ms, so its 49_999_500_000_000
/// left lasts 449_995_500 ms more.
#[test]
fun projected_pools_step_through_run_outs() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_pools_holding(&mut scenario, mw(10), 1, &clock);

    let pools = pools(&mut scenario, entity_id, &clock);
    assert!(pools.length() == 2);
    let own = pools[&fuel_type()];
    assert!(own.pool_view_fuel().quantity() == starting_fuel());
    assert!(own.run_out_ms() == option::some(9_000 + 449_995_500));
    let other_type = OTHER_TYPE;
    let other = pools[&other_type];
    assert!(other.pool_view_fuel().quantity() == power_grid::scale());
    assert!(other.pool_view_fuel().impulse() == OTHER_IMPULSE);
    assert!(other.run_out_ms() == option::some(9_000));

    clock.destroy_for_testing();
    scenario.end();
}

/// Each pool reads how fast it burns now, rounded up like a settle: 10 MW split
/// across both Generators burns the default pool at 55_555_556 a second and the
/// 1-unit pool at 111_111_112. The rates hold until the first run-out, at
/// 9 s; then the default pool carries all 10 MW at 111_111_112 and the empty
/// pool burns nothing.
#[test]
fun projected_pools_read_the_burn_rate() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_pools_holding(&mut scenario, mw(10), 1, &clock);
    let other_type = OTHER_TYPE;

    let pools = pools(&mut scenario, entity_id, &clock);
    let own_rate = pools[&fuel_type()].burn_rate();
    assert!(own_rate == 55_555_556);
    assert!(pools[&other_type].burn_rate() == 111_111_112);

    clock.set_for_testing(4_000);
    let own_left = projected_bay_amount(&mut scenario, entity_id, fuel_bay_id(), &clock);
    let extrapolated = starting_fuel() - own_rate * 4;
    assert!(own_left >= extrapolated && own_left - extrapolated <= 4);
    assert!(pools(&mut scenario, entity_id, &clock)[&fuel_type()].burn_rate() == own_rate);

    clock.set_for_testing(10_000);
    let pools = pools(&mut scenario, entity_id, &clock);
    assert!(pools[&fuel_type()].burn_rate() == 111_111_112);
    assert!(pools[&other_type].burn_rate() == 0);

    clock.destroy_for_testing();
    scenario.end();
}

/// With nothing drawing, no pool runs out; an online Generator's empty pool is listed.
#[test]
fun idle_pools_never_run_out() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[OUTPUT], vector[IMPULSE_LIMIT], &clock);
    install_other_generator(&mut scenario, entity_id, &clock);
    power_up(&mut scenario, entity_id, 2, &clock);

    let pools = pools(&mut scenario, entity_id, &clock);
    assert!(pools[&fuel_type()].run_out_ms().is_none());
    assert!(pools[&fuel_type()].burn_rate() == 0);
    let other_type = OTHER_TYPE;
    let other = pools[&other_type];
    assert!(other.pool_view_fuel().quantity() == 0 && other.run_out_ms().is_none());
    assert!(other.burn_rate() == 0);

    clock.destroy_for_testing();
    scenario.end();
}

// === Snapshot ===

/// The snapshot equals every view it stands for, read at the same clock.
fun assert_snapshot_matches_the_views(scenario: &mut ts::Scenario, entity_id: ID, clock: &Clock) {
    ts::next_tx(scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let snapshot = power_grid::projected_snapshot(&entity, clock);

    assert!(snapshot.snapshot_on() == power_grid::projected_on(&entity, clock));
    let (capacity, used, _) = power_grid::projected_status(&entity, clock);
    assert!(snapshot.snapshot_capacity_mw() == capacity);
    assert!(snapshot.snapshot_used_mw() == used);
    let pools = power_grid::projected_pools(&entity, clock);
    assert!(snapshot.snapshot_pools().length() == pools.length());
    pools
        .keys()
        .do!(|fuel_type| assert!(snapshot.snapshot_pools()[&fuel_type] == pools[&fuel_type]));
    let bays = power_grid::projected_bays(&entity, clock);
    assert!(snapshot.snapshot_bays().length() == bays.length());
    bays.keys().do!(|bay_id| assert!(snapshot.snapshot_bays()[&bay_id] == bays[&bay_id]));

    let states = power_grid::projected_module_states(&entity, clock);
    let statuses = power_grid::module_statuses(&entity, clock);
    let modules = snapshot.snapshot_modules();
    assert!(modules.length() == states.length());
    states.keys().do!(|module_id| {
        let view = modules[&module_id];
        assert!(view.module_view_state() == states[&module_id]);
        assert!(view.module_view_status() == statuses[&module_id]);
    });

    let generators = snapshot.snapshot_generators();
    let installed = *power_grid::power_grid(&entity).generators();
    assert!(generators.length() == installed.length());
    installed.keys().do!(|generator_id| {
        let view = generators[&generator_id];
        assert!(view.generator_view_state() == power_grid::generator_state(&entity, generator_id));
        assert!(
            view.generator_view_status() == power_grid::generator_status(&entity, generator_id, clock),
        );
        assert!(
            view.generator_view_output_mw() == power_grid::projected_output_mw(&entity, generator_id, clock),
        );
    });

    ts::return_shared(entity);
}

/// Before a run-out, mid-stretch, after one pool runs dry and after a refuel
/// with nothing settled: the snapshot always equals the views.
#[test]
fun snapshot_matches_the_views_through_a_run_out() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_pools_holding(&mut scenario, mw(10), 1, &clock);

    assert_snapshot_matches_the_views(&mut scenario, entity_id, &clock);
    clock.set_for_testing(4_000);
    assert_snapshot_matches_the_views(&mut scenario, entity_id, &clock);
    clock.set_for_testing(10_000);
    assert_snapshot_matches_the_views(&mut scenario, entity_id, &clock);
    deposit_typed(
        &mut scenario,
        entity_id,
        FUEL_B,
        OTHER_TYPE,
        5,
        OTHER_IMPULSE,
        thermal(),
        &clock,
    );
    clock.set_for_testing(12_000);
    assert_snapshot_matches_the_views(&mut scenario, entity_id, &clock);

    clock.destroy_for_testing();
    scenario.end();
}

/// A run-out that overloads trips the grid: the snapshot reads it off and
/// nothing drawing, before and after a settle.
#[test]
fun snapshot_reads_a_trip() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_pools_holding(&mut scenario, mw(20), 1, &clock);

    clock.set_for_testing(10_000);
    assert_snapshot_matches_the_views(&mut scenario, entity_id, &clock);
    ts::next_tx(&mut scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    let snapshot = power_grid::projected_snapshot(&entity, &clock);
    assert!(!snapshot.snapshot_on());
    assert!(snapshot.snapshot_capacity_mw() == 0 && snapshot.snapshot_used_mw() == 0);
    ts::return_shared(entity);

    catch_up(&mut scenario, entity_id, MOD_A, &clock);
    assert_snapshot_matches_the_views(&mut scenario, entity_id, &clock);

    clock.destroy_for_testing();
    scenario.end();
}

// === Statuses ===

/// A Generator reads its own pool: empty reads `NoFuel`, held only in an
/// offline bay reads `BaysOffline`, while the other Generator stays `Online`.
#[test]
fun generator_status_reads_its_own_pool() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[OUTPUT], vector[IMPULSE_LIMIT], &clock);
    install_other_generator(&mut scenario, entity_id, &clock);
    power_up(&mut scenario, entity_id, 2, &clock);

    assert!(generator_status(&mut scenario, entity_id, 0, &clock) == power_grid::online_status());
    assert!(generator_status(&mut scenario, entity_id, 1, &clock) == power_grid::no_fuel_status());

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
    assert!(
        generator_status(&mut scenario, entity_id, 1, &clock) == power_grid::bays_offline_status(),
    );
    set_fuel_bay(&mut scenario, entity_id, FUEL_B, true, &clock);
    assert!(generator_status(&mut scenario, entity_id, 1, &clock) == power_grid::online_status());

    clock.destroy_for_testing();
    scenario.end();
}

/// Fuel of a type no online Generator burns doesn't power anything: a module
/// reads `NoFuel`, not `NoPower`.
#[test]
fun fuel_of_another_type_reads_no_fuel() {
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
    install_module(&mut scenario, entity_id, MOD_A, firm_power(mw(10)), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);

    assert!(module_status(&mut scenario, entity_id, &clock) == power_grid::no_fuel_status());

    clock.destroy_for_testing();
    scenario.end();
}

/// One pool empty, the other supplying: the module still reads `Online`.
#[test]
fun one_supplying_pool_keeps_modules_online() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = two_pools_holding(&mut scenario, mw(10), 1, &clock);

    clock.set_for_testing(10_000);
    assert!(module_status(&mut scenario, entity_id, &clock) == power_grid::online_status());
    assert!(generator_status(&mut scenario, entity_id, 1, &clock) == power_grid::no_fuel_status());

    clock.destroy_for_testing();
    scenario.end();
}

// === Generator limits ===

/// Fuel above the Generator's impulse limit is wasted: impulse 90 against a
/// limit of 45 burns as if it were 45, so 10 MW takes 222_222_223 a second instead
/// of the 111_111_112 it would at a limit above 90.
#[test]
fun impulse_above_limit_burns_faster() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[OUTPUT], vector[OTHER_IMPULSE], &clock);
    power_up(&mut scenario, entity_id, 1, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(mw(10)), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);

    clock.set_for_testing(1_000);
    let left = projected_bay_amount(&mut scenario, entity_id, fuel_bay_id(), &clock);
    assert!(left == starting_fuel() - 222_222_223);

    clock.destroy_for_testing();
    scenario.end();
}

// === Several bays and types ===

/// Two bays of the default type and one `OTHER_TYPE` bay; one Generator per
/// type, 20 MW split 10/10. The default Generator's 111_111_112 a second comes off
/// its two bays 2:1 (74_074_075 and 37_037_037, the remainder off the larger); the other
/// Generator burns only its own bay.
#[test]
fun one_type_burns_its_bays_in_proportion_beside_another_type() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[OUTPUT], vector[IMPULSE_LIMIT], &clock);
    install_fuel(&mut scenario, entity_id, FUEL_C, fuel_capacity(), &clock);
    deposit_typed(
        &mut scenario,
        entity_id,
        FUEL_C,
        fuel_type(),
        grid_scenario::starting_units() / 2,
        grid_scenario::impulse(),
        thermal(),
        &clock,
    );
    set_fuel_bay(&mut scenario, entity_id, FUEL_C, true, &clock);
    install_other_generator(&mut scenario, entity_id, &clock);
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
    power_up(&mut scenario, entity_id, 2, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(mw(20)), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);

    clock.set_for_testing(1_000);
    let own_left = projected_bay_amount(&mut scenario, entity_id, fuel_bay_id(), &clock);
    let half_left = projected_bay_amount(&mut scenario, entity_id, FUEL_C, &clock);
    let other_left = projected_bay_amount(&mut scenario, entity_id, FUEL_B, &clock);
    assert!(own_left == starting_fuel() - 74_074_075);
    assert!(half_left == starting_fuel() / 2 - 37_037_037);
    assert!(other_left == OTHER_UNITS * power_grid::scale() - 222_222_223);

    clock.destroy_for_testing();
    scenario.end();
}

// === Emergency Generator ===

/// An Emergency Generator that may burn either type, set to `OTHER_TYPE` and
/// fed by `FUEL_B` holding `other_units`. The default bay holds the other type.
/// Grid on, the Generator online, `MOD_A` drawing 10 MW.
fun emergency_on_other(scenario: &mut ts::Scenario, other_units: u64, clock: &Clock): ID {
    let entity_id = setup_entity(scenario, vector[], vector[], clock);
    install_generator(
        scenario,
        entity_id,
        generator_id(0),
        OTHER_TYPE,
        vector[OTHER_TYPE, fuel_type()],
        OUTPUT,
        IMPULSE_LIMIT,
        volatility_limit(),
        clock,
    );
    install_fuel(scenario, entity_id, FUEL_B, fuel_capacity(), clock);
    deposit_typed(
        scenario,
        entity_id,
        FUEL_B,
        OTHER_TYPE,
        other_units,
        OTHER_IMPULSE,
        thermal(),
        clock,
    );
    set_fuel_bay(scenario, entity_id, FUEL_B, true, clock);
    power_up(scenario, entity_id, 1, clock);
    install_module(scenario, entity_id, MOD_A, firm_power(mw(10)), clock);
    set_desired(scenario, entity_id, MOD_A, true, clock);
    entity_id
}

/// Owner switches Generator 0 offline, sets it to `fuel_type`, brings it back
/// and switches the grid on.
fun switch_emergency_to(scenario: &mut ts::Scenario, entity_id: ID, fuel_type: u64, clock: &Clock) {
    grid_scenario::set_generator(scenario, entity_id, 0, false, clock);
    grid_scenario::set_generator_fuel_type(scenario, entity_id, generator_id(0), fuel_type);
    grid_scenario::set_generator(scenario, entity_id, 0, true, clock);
    grid_scenario::power(scenario, entity_id, true, clock);
}

/// Its 1-unit pool runs dry at 4.5 s. It never switches to the full default
/// pool by itself: nothing draws and the default bay keeps its fuel until the
/// owner sets the other type.
#[test]
fun emergency_stops_when_its_type_runs_dry() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = emergency_on_other(&mut scenario, 1, &clock);

    clock.set_for_testing(10_000);
    assert!(capacity(&mut scenario, entity_id, &clock) == 0);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == 0);
    let own_left = projected_bay_amount(&mut scenario, entity_id, fuel_bay_id(), &clock);
    assert!(own_left == starting_fuel());
    ts::next_tx(&mut scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    let state = power_grid::generator_state(&entity, generator_id(0));
    assert!(state.online() && state.generator_fuel_type() == OTHER_TYPE);
    ts::return_shared(entity);

    switch_emergency_to(&mut scenario, entity_id, fuel_type(), &clock);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == mw(10));

    clock.destroy_for_testing();
    scenario.end();
}

/// After the owner sets it to the default type, power follows the default pool:
/// it burns 111_111_112 a second there and the `OTHER_TYPE` bay keeps its fuel.
#[test]
fun emergency_set_to_another_type_burns_that_pool() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = emergency_on_other(&mut scenario, OTHER_UNITS, &clock);

    switch_emergency_to(&mut scenario, entity_id, fuel_type(), &clock);

    clock.set_for_testing(1_000);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == mw(10));
    let own_left = projected_bay_amount(&mut scenario, entity_id, fuel_bay_id(), &clock);
    let other_left = projected_bay_amount(&mut scenario, entity_id, FUEL_B, &clock);
    assert!(own_left == starting_fuel() - 111_111_112);
    assert!(other_left == OTHER_UNITS * power_grid::scale());

    clock.destroy_for_testing();
    scenario.end();
}
