#[test_only]
module power::migrate_tests;

use core::entity::Entity;
use power::{
    grid_fuel,
    grid_generator,
    grid_load,
    grid_scenario::{
        admin,
        burden,
        firm_power,
        fuel_capacity,
        fuel_source_id,
        generator_id,
        impulse,
        install_fuel,
        install_module,
        migrate_fuel,
        migrate_generator,
        migrate_module,
        owner,
        power_up,
        set_desired,
        settled_fuel,
        setup_empty_grid,
        setup_empty_grid_in_tenant,
        setup_entity,
        starting_fuel,
        stored_draw
    },
    power_grid
};
use sui::{clock::{Self, Clock}, test_scenario as ts};

const MOD_A: u64 = 401;
/// 15 MW at `SCALE`.
const OUTPUT: u64 = 150_000;
/// 25 MW at `SCALE`.
const OUTPUT_2: u64 = 250_000;
const CONTAINMENT: u64 = 100_000;
/// 10 MW at `SCALE`.
const DRAW: u64 = 100_000;
const SECOND_FUEL_ID: u64 = 9_002;

fun grid_of(scenario: &mut ts::Scenario, entity_id: ID): (u64, u64, u64, u64, u64) {
    ts::next_tx(scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let grid = power_grid::power_grid(&entity);
    let capacity_mw = grid.capacity_mw();
    let fuel_capacity = grid.fuel_capacity();
    let fuel = grid.fuel_quantity_at_last_settled();
    let fuel_impulse = grid.fuel_impulse();
    let fuel_burden = grid.fuel_containment_burden();
    ts::return_shared(entity);
    (capacity_mw, fuel_capacity, fuel, fuel_impulse, fuel_burden)
}

macro fun with_entity<$R>($scenario: &mut ts::Scenario, $entity_id: ID, $f: |&Entity| -> $R): $R {
    let scenario = $scenario;
    ts::next_tx(scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(scenario, $entity_id);
    let r = $f(&entity);
    ts::return_shared(entity);
    r
}

// === modules ===

#[test]
fun migrate_module_keeps_spec_and_desired_state() {
    let mut scenario = ts::begin(admin());
    let clock = clock::create_for_testing(scenario.ctx());
    core::test_helpers::setup(&mut scenario);
    let from = setup_entity(&mut scenario, vector[OUTPUT], vector[CONTAINMENT], &clock);
    power_up(&mut scenario, from, 1, &clock);
    install_module(&mut scenario, from, MOD_A, firm_power(DRAW), &clock);
    set_desired(&mut scenario, from, MOD_A, true, &clock);
    assert!(stored_draw(&mut scenario, from, MOD_A) == DRAW);
    let to = setup_empty_grid(&mut scenario, 2, &clock);

    migrate_module(&mut scenario, admin(), from, to, MOD_A, true, &clock);

    ts::next_tx(&mut scenario, owner());
    let from_e = ts::take_shared_by_id<Entity>(&scenario, from);
    let to_e = ts::take_shared_by_id<Entity>(&scenario, to);
    assert!(!power_grid::power_grid(&from_e).is_module_connected(MOD_A));
    let state = power_grid::power_grid(&to_e).module_state(MOD_A);
    assert!(state.power_req() == DRAW);
    assert!(state.draw_kind().is_firm());
    assert!(state.desired_online());
    // `to` has no capacity, so the module draws nothing there.
    assert!(state.active_draw_at_last_settled() == 0);
    ts::return_shared(from_e);
    ts::return_shared(to_e);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = grid_load::EModuleStillInstalled)]
fun migrate_module_still_on_source_aborts() {
    let mut scenario = ts::begin(admin());
    let clock = clock::create_for_testing(scenario.ctx());
    core::test_helpers::setup(&mut scenario);
    let from = setup_entity(&mut scenario, vector[], vector[], &clock);
    install_module(&mut scenario, from, MOD_A, firm_power(DRAW), &clock);
    let to = setup_empty_grid(&mut scenario, 2, &clock);

    migrate_module(&mut scenario, admin(), from, to, MOD_A, false, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_load::EWrongTenant)]
fun migrate_module_across_tenants_aborts() {
    let mut scenario = ts::begin(admin());
    let clock = clock::create_for_testing(scenario.ctx());
    core::test_helpers::setup(&mut scenario);
    let from = setup_entity(&mut scenario, vector[], vector[], &clock);
    install_module(&mut scenario, from, MOD_A, firm_power(DRAW), &clock);
    let to = setup_empty_grid_in_tenant(&mut scenario, 2, b"OTHER", &clock);

    migrate_module(&mut scenario, admin(), from, to, MOD_A, true, &clock);

    abort
}

// === generators ===

#[test]
fun migrate_generator_moves_its_output_and_online_state() {
    let mut scenario = ts::begin(admin());
    let clock = clock::create_for_testing(scenario.ctx());
    core::test_helpers::setup(&mut scenario);
    let from = setup_entity(
        &mut scenario,
        vector[OUTPUT, OUTPUT_2],
        vector[CONTAINMENT, CONTAINMENT],
        &clock,
    );
    power_up(&mut scenario, from, 2, &clock);
    let to = setup_empty_grid(&mut scenario, 2, &clock);

    migrate_generator(&mut scenario, admin(), from, to, generator_id(0), &clock);

    let (from_capacity, _, _, _, _) = grid_of(&mut scenario, from);
    let (to_capacity, _, _, _, _) = grid_of(&mut scenario, to);
    assert!(from_capacity == OUTPUT_2);
    assert!(to_capacity == OUTPUT);
    assert!(
        !with_entity!(
            &mut scenario,
            from,
            |e| power_grid::is_generator_connected(e, generator_id(0)),
        ),
    );
    let state = with_entity!(
        &mut scenario,
        to,
        |e| power_grid::generator_state(e, generator_id(0)),
    );
    assert!(state.online());
    assert!(state.max_output_mw() == OUTPUT);
    assert!(state.containment_reduction() == CONTAINMENT);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = core::admin_service::EUnauthorizedAdmin)]
fun migrate_generator_by_non_admin_aborts() {
    let mut scenario = ts::begin(admin());
    let clock = clock::create_for_testing(scenario.ctx());
    core::test_helpers::setup(&mut scenario);
    let from = setup_entity(&mut scenario, vector[OUTPUT], vector[CONTAINMENT], &clock);
    let to = setup_empty_grid(&mut scenario, 2, &clock);

    migrate_generator(&mut scenario, owner(), from, to, generator_id(0), &clock);

    abort
}

#[test, expected_failure(abort_code = grid_generator::EWrongTenant)]
fun migrate_generator_across_tenants_aborts() {
    let mut scenario = ts::begin(admin());
    let clock = clock::create_for_testing(scenario.ctx());
    core::test_helpers::setup(&mut scenario);
    let from = setup_entity(&mut scenario, vector[OUTPUT], vector[CONTAINMENT], &clock);
    let to = setup_empty_grid_in_tenant(&mut scenario, 2, b"OTHER", &clock);

    migrate_generator(&mut scenario, admin(), from, to, generator_id(0), &clock);

    abort
}

// === fuel ===

#[test]
fun migrate_fuel_moves_its_share_of_the_pool() {
    let mut scenario = ts::begin(admin());
    let clock = clock::create_for_testing(scenario.ctx());
    core::test_helpers::setup(&mut scenario);
    let from = setup_entity(&mut scenario, vector[], vector[], &clock);
    install_fuel(&mut scenario, from, SECOND_FUEL_ID, 3 * fuel_capacity(), &clock);
    let to = setup_empty_grid(&mut scenario, 2, &clock);

    migrate_fuel(&mut scenario, admin(), from, to, fuel_source_id(), &clock);

    // The source holds a quarter of the capacity, so it takes a quarter of the fuel.
    let moved = starting_fuel() / 4;
    let (_, from_cap, from_fuel, from_impulse, _) = grid_of(&mut scenario, from);
    let (_, to_cap, to_fuel, to_impulse, to_burden) = grid_of(&mut scenario, to);
    assert!(from_cap == 3 * fuel_capacity() && from_fuel == starting_fuel() - moved);
    assert!(from_impulse == impulse());
    assert!(to_cap == fuel_capacity() && to_fuel == moved);
    assert!(to_impulse == impulse() && to_burden == burden());

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun migrate_last_fuel_source_takes_all_fuel() {
    let mut scenario = ts::begin(admin());
    let clock = clock::create_for_testing(scenario.ctx());
    core::test_helpers::setup(&mut scenario);
    let from = setup_entity(&mut scenario, vector[], vector[], &clock);
    let to = setup_empty_grid(&mut scenario, 2, &clock);

    migrate_fuel(&mut scenario, admin(), from, to, fuel_source_id(), &clock);

    assert!(settled_fuel(&mut scenario, from) == 0);
    assert!(settled_fuel(&mut scenario, to) == starting_fuel());
    let (_, from_cap, _, _, _) = grid_of(&mut scenario, from);
    assert!(from_cap == 0);

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun migrate_fuel_settles_burn_first() {
    let mut scenario = ts::begin(admin());
    let mut clock = clock::create_for_testing(scenario.ctx());
    core::test_helpers::setup(&mut scenario);
    let from = setup_entity(&mut scenario, vector[OUTPUT], vector[CONTAINMENT], &clock);
    power_up(&mut scenario, from, 1, &clock);
    install_module(&mut scenario, from, MOD_A, firm_power(DRAW), &clock);
    set_desired(&mut scenario, from, MOD_A, true, &clock);
    let to = setup_empty_grid(&mut scenario, 2, &clock);
    clock.increment_for_testing(60_000);
    let left = with_entity!(&mut scenario, from, |e| power_grid::projected_fuel(e, &clock));
    assert!(left < starting_fuel());

    migrate_fuel(&mut scenario, admin(), from, to, fuel_source_id(), &clock);

    assert!(settled_fuel(&mut scenario, to) == left);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = power_grid::EFuelSourceNotConnected)]
fun migrate_unknown_fuel_source_aborts() {
    let mut scenario = ts::begin(admin());
    let clock = clock::create_for_testing(scenario.ctx());
    core::test_helpers::setup(&mut scenario);
    let from = setup_entity(&mut scenario, vector[], vector[], &clock);
    let to = setup_empty_grid(&mut scenario, 2, &clock);

    migrate_fuel(&mut scenario, admin(), from, to, SECOND_FUEL_ID, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EWrongTenant)]
fun migrate_fuel_across_tenants_aborts() {
    let mut scenario = ts::begin(admin());
    let clock = clock::create_for_testing(scenario.ctx());
    core::test_helpers::setup(&mut scenario);
    let from = setup_entity(&mut scenario, vector[], vector[], &clock);
    let to = setup_empty_grid_in_tenant(&mut scenario, 2, b"OTHER", &clock);

    migrate_fuel(&mut scenario, admin(), from, to, fuel_source_id(), &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::EComponentMissing)]
fun migrate_fuel_to_entity_without_grid_aborts() {
    let mut scenario = ts::begin(admin());
    let clock = clock::create_for_testing(scenario.ctx());
    core::test_helpers::setup(&mut scenario);
    let from = setup_entity(&mut scenario, vector[], vector[], &clock);
    ts::next_tx(&mut scenario, admin());
    let mut registry = core::test_helpers::take_registry(&scenario);
    let acl = core::test_helpers::take_acl(&scenario);
    let bare = core::test_helpers::claim(&mut registry, &acl, 2, scenario.ctx());
    let to = bare.id();
    bare.share();
    ts::return_shared(registry);
    ts::return_shared(acl);

    migrate_fuel(&mut scenario, admin(), from, to, fuel_source_id(), &clock);

    abort
}
