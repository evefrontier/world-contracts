#[test_only]
module power::grid_load_tests;

use core::{entity::Entity, test_helpers::{claim, setup, take_acl, take_registry}};
use power::{
    grid_load,
    grid_scenario::{
        Self,
        catch_up,
        deposit_fuel,
        draw,
        firm_power,
        elastic_power,
        install_module,
        power,
        power_up,
        projected,
        set_desired,
        set_priority,
        setup_entity,
        settled_fuel,
        starting_fuel,
        stored_draw,
        temp_action,
        uninstall_module,
        impulse,
        burden,
        admin,
        owner
    },
    power_grid
};
use sui::{clock::{Self, Clock}, test_scenario as ts};

const MOD_A: u64 = 401;
const MOD_B: u64 = 402;
const MOD_E: u64 = 403;
/// 15 MW at `SCALE`.
const OUTPUT: u64 = 150_000;
/// Containment reduction 10 at `SCALE`.
const CONTAINMENT: u64 = 100_000;
/// 10 MW at `SCALE`.
const DRAW: u64 = 100_000;
/// Long enough at 10 MW that the whole tank burns, in ms.
const DEPLETING_MS: u64 = 10_000_000_000_000;

/// Grid on, one online Generator of `OUTPUT`, fuel full. Modules are installed by the test.
fun powered(scenario: &mut ts::Scenario, clock: &Clock): ID {
    let entity_id = setup_entity(scenario, vector[OUTPUT], vector[CONTAINMENT], clock);
    power_up(scenario, entity_id, 1, clock);
    entity_id
}

/// `(live draw, desired_online, connected module count)` at `clock`.
fun projected_module(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    module_id: u64,
    clock: &Clock,
): (u64, bool, u64) {
    ts::next_tx(scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let states = power_grid::power_grid(&entity).projected_module_states(clock);
    let live_draw = states.get(&module_id).active_draw_at_last_settled();
    let desired = states.get(&module_id).desired_online();
    let count = states.length();
    ts::return_shared(entity);
    (live_draw, desired, count)
}

/// `(online, desired_online, draw_at_last_settle)` for `module_id`, as of the last settle.
fun module_flags(scenario: &mut ts::Scenario, entity_id: ID, module_id: u64): (bool, bool, u64) {
    ts::next_tx(scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let state = power_grid::power_grid(&entity).module_state(module_id);
    let granted = state.active_draw_at_last_settled();
    let desired = state.desired_online();
    ts::return_shared(entity);
    (granted > 0, desired, granted)
}

// === Connect and disconnect ===

#[test]
fun install_connects_module_offline() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);

    let (online, desired, granted) = module_flags(&mut scenario, entity_id, MOD_A);
    assert!(!online);
    assert!(!desired);
    assert!(granted == 0);

    clock.destroy_for_testing();
    scenario.end();
}

/// Modules cannot connect to a Creation without an installed grid.
#[test, expected_failure(abort_code = power_grid::EComponentMissing)]
fun install_without_grid_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    ts::next_tx(&mut scenario, admin());
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let entity = claim(&mut registry, &acl, 2, scenario.ctx());
    let entity_id = entity.id();
    entity.share();
    ts::return_shared(acl);
    ts::return_shared(registry);

    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);

    abort
}

#[test]
fun uninstall_disconnects_and_others_regrant() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);
    install_module(&mut scenario, entity_id, MOD_E, elastic_power(DRAW), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);
    set_desired(&mut scenario, entity_id, MOD_E, true, &clock);
    assert!(draw(&mut scenario, entity_id, MOD_E, &clock) == OUTPUT - DRAW);

    uninstall_module(&mut scenario, entity_id, MOD_A, &clock);
    assert!(draw(&mut scenario, entity_id, MOD_E, &clock) == DRAW);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = power_grid::EModuleNotConnected)]
fun desired_state_on_unknown_module_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_load::EZeroPowerReq)]
fun connect_zero_power_req_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(0), &clock);

    abort
}

// === Desired state and grants ===

#[test]
fun desired_firm_module_draws_when_it_fits() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);

    let (_, _, used, online) = projected(&mut scenario, entity_id, &clock);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == DRAW);
    assert!(used == DRAW);
    assert!(online == vector[MOD_A]);
    assert!(stored_draw(&mut scenario, entity_id, MOD_A) == DRAW);

    clock.destroy_for_testing();
    scenario.end();
}

/// Firm draws are all or nothing: when two desired Firm modules do not both fit,
/// neither draws, and both draw again once one steps down.
#[test]
fun firm_modules_are_all_or_nothing() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);
    install_module(&mut scenario, entity_id, MOD_B, firm_power(DRAW), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == DRAW);

    set_desired(&mut scenario, entity_id, MOD_B, true, &clock);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == 0);
    assert!(draw(&mut scenario, entity_id, MOD_B, &clock) == 0);

    set_desired(&mut scenario, entity_id, MOD_B, false, &clock);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == DRAW);

    clock.destroy_for_testing();
    scenario.end();
}

/// Elastic takes the leftover after Firm, up to its own ask.
#[test]
fun elastic_takes_leftover_after_firm() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);
    install_module(&mut scenario, entity_id, MOD_E, elastic_power(DRAW), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);
    set_desired(&mut scenario, entity_id, MOD_E, true, &clock);

    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == DRAW);
    assert!(draw(&mut scenario, entity_id, MOD_E, &clock) == OUTPUT - DRAW);

    clock.destroy_for_testing();
    scenario.end();
}

/// Elastic never blocks Firm: a Firm module that fits still draws in full.
#[test]
fun elastic_does_not_block_firm() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, &clock);
    install_module(&mut scenario, entity_id, MOD_E, elastic_power(OUTPUT), &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);
    set_desired(&mut scenario, entity_id, MOD_E, true, &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);

    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == DRAW);

    clock.destroy_for_testing();
    scenario.end();
}

/// Intent is accepted with no power, and draws once the grid comes on.
#[test]
fun desired_state_is_stored_without_power() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[OUTPUT], vector[CONTAINMENT], &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);

    let (online, desired, granted) = module_flags(&mut scenario, entity_id, MOD_A);
    assert!(!online);
    assert!(desired);
    assert!(granted == 0);

    power(&mut scenario, entity_id, true, &clock);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == 0);
    grid_scenario::set_generator(&mut scenario, entity_id, 0, true, &clock);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == DRAW);

    clock.destroy_for_testing();
    scenario.end();
}

/// Switching the grid off drops every grant, and switching it back on regrants
/// without any owner action on the modules.
#[test]
fun power_off_drops_and_power_on_regrants() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);

    power(&mut scenario, entity_id, false, &clock);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == 0);
    assert!(stored_draw(&mut scenario, entity_id, MOD_A) == 0);
    let (_, desired, _) = module_flags(&mut scenario, entity_id, MOD_A);
    assert!(desired);

    power(&mut scenario, entity_id, true, &clock);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == DRAW);

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun generator_offline_drops_and_online_regrants() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);

    grid_scenario::set_generator(&mut scenario, entity_id, 0, false, &clock);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == 0);
    grid_scenario::set_generator(&mut scenario, entity_id, 0, true, &clock);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == DRAW);

    clock.destroy_for_testing();
    scenario.end();
}

/// Priority is stored but grants ignore it in v1.
#[test]
fun priority_does_not_change_grants() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);
    set_priority(&mut scenario, entity_id, MOD_A, 7, &clock);

    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == DRAW);
    ts::next_tx(&mut scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    assert!(power_grid::power_grid(&entity).module_state(MOD_A).priority() == 7);
    ts::return_shared(entity);

    clock.destroy_for_testing();
    scenario.end();
}

// === Fuel depletion ===

/// Depletion writes nothing on its own. The views read zero, and the stored
/// grant and fuel stay until the next settle.
#[test]
fun depletion_is_view_only_until_settle() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);

    let (live_draw, desired, count) = projected_module(&mut scenario, entity_id, MOD_A, &clock);
    assert!(live_draw == DRAW);
    assert!(desired);
    assert!(count == 1);

    clock.set_for_testing(DEPLETING_MS);
    let (fuel_left, capacity, used, online) = projected(&mut scenario, entity_id, &clock);
    assert!(fuel_left == 0);
    assert!(capacity == 0);
    assert!(used == 0);
    assert!(online.is_empty());
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == 0);
    let (live_draw, desired, count) = projected_module(&mut scenario, entity_id, MOD_A, &clock);
    assert!(live_draw == 0);
    assert!(desired);
    assert!(count == 1);
    assert!(stored_draw(&mut scenario, entity_id, MOD_A) == DRAW);
    assert!(settled_fuel(&mut scenario, entity_id) == starting_fuel());

    catch_up(&mut scenario, entity_id, MOD_A, &clock);
    assert!(settled_fuel(&mut scenario, entity_id) == 0);
    assert!(stored_draw(&mut scenario, entity_id, MOD_A) == 0);
    let (_, desired, _) = module_flags(&mut scenario, entity_id, MOD_A);
    assert!(desired);

    clock.destroy_for_testing();
    scenario.end();
}

/// Refuelling regrants the desired module with no action from the owner.
#[test]
fun refuel_regrants_desired_module() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);

    clock.set_for_testing(DEPLETING_MS);
    catch_up(&mut scenario, entity_id, MOD_A, &clock);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == 0);

    deposit_fuel(&mut scenario, entity_id, 1_000_000, impulse(), burden(), &clock);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == DRAW);

    clock.destroy_for_testing();
    scenario.end();
}

// === Consumer checks ===

#[test]
fun online_check_passes_while_granted() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);

    temp_action!(
        &mut scenario,
        entity_id,
        power_grid::online_requirement(MOD_A, DRAW, power_grid::firm()),
        |entity, req| grid_load::assert_online(entity, req, &clock),
    );

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = grid_load::ENoGrant)]
fun online_check_aborts_when_not_desired() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);

    temp_action!(
        &mut scenario,
        entity_id,
        power_grid::online_requirement(MOD_A, DRAW, power_grid::firm()),
        |entity, req| grid_load::assert_online(entity, req, &clock),
    );

    abort
}

#[test, expected_failure(abort_code = grid_load::EOutOfFuel)]
fun online_check_aborts_after_fuel_runs_out() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);

    clock.set_for_testing(DEPLETING_MS);
    temp_action!(
        &mut scenario,
        entity_id,
        power_grid::online_requirement(MOD_A, DRAW, power_grid::firm()),
        |entity, req| grid_load::assert_online(entity, req, &clock),
    );

    abort
}
