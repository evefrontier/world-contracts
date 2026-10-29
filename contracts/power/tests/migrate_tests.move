#[test_only]
module power::migrate_tests;

use core::entity::Entity;
use power::{
    grid_fuel,
    grid_generator,
    grid_load,
    grid_scenario::{
        admin,
        bay_fuel,
        burden,
        firm_power,
        fuel_bay_id,
        fuel_capacity,
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
        stored_draw,
        volatility
    },
    power_grid
};
use sui::{clock::{Self, Clock}, test_scenario as ts};

const MOD_A: u64 = 401;
/// 15 MW.
const OUTPUT: u64 = 15;
/// 25 MW.
const OUTPUT_2: u64 = 25;
const CONTAINMENT: u64 = 10;
/// 10 MW.
const DRAW: u64 = 10;
const SECOND_FUEL_ID: u64 = 9_002;

/// `(capacity_mw, bay count)` of the grid.
fun grid_of(scenario: &mut ts::Scenario, entity_id: ID): (u64, u64) {
    ts::next_tx(scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let grid = power_grid::power_grid(&entity);
    let capacity_mw = grid.capacity_mw();
    let bay_count = grid.bays().length();
    ts::return_shared(entity);
    (capacity_mw, bay_count)
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

    let (from_capacity, _) = grid_of(&mut scenario, from);
    let (to_capacity, _) = grid_of(&mut scenario, to);
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

/// The bay moves with exactly its own fuel and arrives offline. The bay left
/// behind keeps all of its own.
#[test]
fun migrate_fuel_moves_the_bays_exact_fuel() {
    let mut scenario = ts::begin(admin());
    let clock = clock::create_for_testing(scenario.ctx());
    core::test_helpers::setup(&mut scenario);
    let from = setup_entity(&mut scenario, vector[], vector[], &clock);
    install_fuel(&mut scenario, from, SECOND_FUEL_ID, fuel_capacity(), &clock);
    let to = setup_empty_grid(&mut scenario, 2, &clock);

    migrate_fuel(&mut scenario, admin(), from, to, fuel_bay_id(), &clock);

    let moved = bay_fuel(&mut scenario, to, fuel_bay_id());
    assert!(moved.quantity() == starting_fuel());
    assert!(moved.impulse() == impulse() && moved.containment_burden() == burden());
    assert!(moved.volatility() == volatility());
    let capacity = with_entity!(&mut scenario, to, |e| {
        power_grid::fuel_bay_state(e, fuel_bay_id()).capacity()
    });
    assert!(capacity == fuel_capacity());
    assert!(settled_fuel(&mut scenario, to) == 0);
    let (_, from_bays) = grid_of(&mut scenario, from);
    assert!(from_bays == 1);
    assert!(bay_fuel(&mut scenario, from, SECOND_FUEL_ID).quantity() == 0);

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

    migrate_fuel(&mut scenario, admin(), from, to, fuel_bay_id(), &clock);

    assert!(bay_fuel(&mut scenario, to, fuel_bay_id()).quantity() == left);
    assert!(stored_draw(&mut scenario, from, MOD_A) == 0);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = power_grid::EFuelBayNotConnected)]
fun migrate_unknown_fuel_bay_aborts() {
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

    migrate_fuel(&mut scenario, admin(), from, to, fuel_bay_id(), &clock);

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

    migrate_fuel(&mut scenario, admin(), from, to, fuel_bay_id(), &clock);

    abort
}
