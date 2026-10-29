#[test_only]
module power::fits_tests;

use core::{entity::Entity, test_helpers::setup};
use power::{
    grid_generator,
    grid_load,
    grid_scenario::{
        Self,
        admin,
        draw,
        elastic_power,
        enable_fitted,
        firm_power,
        generator_id,
        install_module,
        owner,
        power_up,
        set_desired,
        set_priority,
        setup_entity
    },
    power_grid
};
use sui::{clock::{Self, Clock}, test_scenario as ts};

/// The overview's modules on a 100 MW limit.
const A: u64 = 501;
const B: u64 = 502;
const C: u64 = 503;
const D: u64 = 504;
const E: u64 = 505;
/// Containment reduction 10.
const CONTAINMENT: u64 = 10;

// === Helpers ===

/// One 100 MW Generator (or the given split), grid on, the overview's modules
/// installed and offline, and the owner's pre-filtered action exposed.
fun overview(scenario: &mut ts::Scenario, outputs: vector<u64>, clock: &Clock): ID {
    let count = outputs.length();
    let containments = vector::tabulate!(count, |_| CONTAINMENT);
    let entity_id = setup_entity(scenario, outputs, containments, clock);
    power_up(scenario, entity_id, count, clock);
    install_module(scenario, entity_id, A, firm_power(70), clock);
    install_module(scenario, entity_id, B, firm_power(20), clock);
    install_module(scenario, entity_id, C, elastic_power(30), clock);
    install_module(scenario, entity_id, D, firm_power(10), clock);
    install_module(scenario, entity_id, E, firm_power(20), clock);
    enable_fitted(scenario, entity_id);
    entity_id
}

/// Switch `module_id` on through the pre-filtered action.
fun fitted_on(scenario: &mut ts::Scenario, entity_id: ID, module_id: u64, clock: &Clock) {
    grid_scenario::fitted!(
        scenario,
        entity_id,
        |entity, req| grid_load::set_desired_state(entity, req, module_id, true, clock),
    );
}

/// A builder's shed order: grant Firm modules in priority order, skipping any
/// that no longer fits; Elastic modules ask for whatever is left.
fun grant_in_rank_order(scenario: &mut ts::Scenario, entity_id: ID, clock: &Clock) {
    ts::next_tx(scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let grid = power_grid::power_grid(&entity);
    let mut ranked = vector[];
    grid.modules().length().do!(|i| {
        let (module_id, _) = grid.modules().get_entry_by_idx(i);
        ranked.push_back(*module_id);
    });
    // Insertion sort by priority: tens of modules at most.
    let count = ranked.length();
    let mut i = 1;
    while (i < count) {
        let mut j = i;
        while (
            j > 0 && grid.module_state(ranked[j - 1]).priority() > grid.module_state(ranked[j]).priority()
        ) {
            ranked.swap(j - 1, j);
            j = j - 1;
        };
        i = i + 1;
    };
    let mut spare = grid.capacity_mw();
    let mut chosen = vector[];
    ranked.do!(|module_id| {
        let state = grid.module_state(module_id);
        if (!state.draw_kind().is_firm()) chosen.push_back(module_id)
        else if (state.power_req() <= spare) {
            spare = spare - state.power_req();
            chosen.push_back(module_id);
        };
    });
    ts::return_shared(entity);
    chosen.do!(|module_id| set_desired(scenario, entity_id, module_id, true, clock));
}

// === Pre-filter ===

#[test]
fun fitting_switch_on_passes_the_pre_filter() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = overview(&mut scenario, vector[100], &clock);

    fitted_on(&mut scenario, entity_id, A, &clock);
    fitted_on(&mut scenario, entity_id, B, &clock);
    fitted_on(&mut scenario, entity_id, D, &clock);

    assert!(draw(&mut scenario, entity_id, A, &clock) == 70);
    assert!(draw(&mut scenario, entity_id, B, &clock) == 20);
    assert!(draw(&mut scenario, entity_id, D, &clock) == 10);

    clock.destroy_for_testing();
    scenario.end();
}

/// E would push Firm to 120 MW of 100: the switch-on aborts instead of the overload.
#[test, expected_failure(abort_code = power_grid::EWouldOverload)]
fun overloading_switch_on_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = overview(&mut scenario, vector[100], &clock);
    fitted_on(&mut scenario, entity_id, A, &clock);
    fitted_on(&mut scenario, entity_id, B, &clock);

    fitted_on(&mut scenario, entity_id, E, &clock);

    abort
}

/// Elastic asks never overload, so the pre-filter lets them through.
#[test]
fun elastic_switch_on_passes_the_pre_filter() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = overview(&mut scenario, vector[100], &clock);
    fitted_on(&mut scenario, entity_id, A, &clock);
    fitted_on(&mut scenario, entity_id, B, &clock);
    fitted_on(&mut scenario, entity_id, D, &clock);

    fitted_on(&mut scenario, entity_id, C, &clock);

    assert!(draw(&mut scenario, entity_id, C, &clock) == 0);

    clock.destroy_for_testing();
    scenario.end();
}

/// Taking a 40 MW Generator offline under a 70 MW load would overload: it aborts.
#[test, expected_failure(abort_code = power_grid::EWouldOverload)]
fun generator_offline_that_overloads_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = overview(&mut scenario, vector[60, 40], &clock);
    fitted_on(&mut scenario, entity_id, A, &clock);

    grid_scenario::fitted!(
        &mut scenario,
        entity_id,
        |entity, req| grid_generator::set_generator(entity, req, generator_id(1), false, &clock),
    );

    abort
}

// === Builder shed order ===

/// The overview's ranked example: A (rank 1), E (2), B (3), D and C (4). Granting
/// in rank order and skipping what doesn't fit runs A, E and D on 100 MW; B
/// stays off and C gets nothing to charge with.
#[test]
fun builder_grants_in_rank_order() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = overview(&mut scenario, vector[100], &clock);
    set_priority(&mut scenario, entity_id, A, 1, &clock);
    set_priority(&mut scenario, entity_id, E, 2, &clock);
    set_priority(&mut scenario, entity_id, B, 3, &clock);
    set_priority(&mut scenario, entity_id, D, 4, &clock);
    set_priority(&mut scenario, entity_id, C, 4, &clock);

    grant_in_rank_order(&mut scenario, entity_id, &clock);

    assert!(draw(&mut scenario, entity_id, A, &clock) == 70);
    assert!(draw(&mut scenario, entity_id, E, &clock) == 20);
    assert!(draw(&mut scenario, entity_id, D, &clock) == 10);
    assert!(draw(&mut scenario, entity_id, B, &clock) == 0);
    assert!(draw(&mut scenario, entity_id, C, &clock) == 0);

    clock.destroy_for_testing();
    scenario.end();
}
