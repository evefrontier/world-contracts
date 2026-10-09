#[test_only]
module power::shed_tests;

use core::test_helpers::setup;
use power::{
    grid_load::{Self, Reserved},
    grid_scenario::{
        active,
        connect,
        has_reservation,
        power,
        power_up,
        reserve_elastic,
        reserve_firm,
        set_generator,
        setup_entity,
        used
    },
    power_grid::{Self, Shed}
};
use sui::{clock::{Self, Clock}, event, test_scenario as ts};

const ADMIN: address = @0xA;
const MOD_A: u64 = 301;
const MOD_B: u64 = 302;
const MOD_C: u64 = 303;

// === Helpers ===

/// Generators with `max_outputs_mw`, all online, grid on.
fun powered(scenario: &mut ts::Scenario, max_outputs_mw: vector<u64>, clock: &Clock): ID {
    let count = max_outputs_mw.length();
    let entity_id = setup_entity(scenario, max_outputs_mw, vector[MOD_A, MOD_B, MOD_C], clock);
    power_up(scenario, entity_id, count, clock);
    entity_id
}

/// Module ids in this tx's `Shed` events, in emit order.
fun shed_modules(): vector<u64> {
    event::events_by_type<Shed>().map!(|shed| {
        let (_, module_id) = shed.shed_fields();
        module_id
    })
}

// === Shed ===

/// A generator going offline sheds the reservation; back online, nothing is
/// regranted, but a new reserve fits again.
#[test]
fun generator_offline_sheds_and_online_allows_new_reserve() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, vector[50], &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 25, &clock);

    set_generator(&mut scenario, entity_id, 0, false, &clock);
    assert!(shed_modules() == vector[MOD_A]);
    assert!(!has_reservation(&mut scenario, entity_id, MOD_A));
    assert!(used(&mut scenario, entity_id) == 0);

    set_generator(&mut scenario, entity_id, 0, true, &clock);
    assert!(event::events_by_type<Reserved>().is_empty());
    assert!(!has_reservation(&mut scenario, entity_id, MOD_A));

    reserve_firm(&mut scenario, entity_id, MOD_A, 25, &clock);
    assert!(active(&mut scenario, entity_id, MOD_A) == 25);

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun shed_highest_priority_value_first() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, vector[30, 20], &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);
    connect(&mut scenario, entity_id, MOD_B, 5, 1, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 20, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_B, 20, &clock);
    assert!(used(&mut scenario, entity_id) == 45);

    // 50 -> 30: shedding B (priority group 1) and its line loss is enough.
    set_generator(&mut scenario, entity_id, 1, false, &clock);
    assert!(shed_modules() == vector[MOD_B]);
    assert!(active(&mut scenario, entity_id, MOD_A) == 20);
    assert!(used(&mut scenario, entity_id) == 20);

    clock.destroy_for_testing();
    scenario.end();
}

/// A whole priority group goes, even when one member would be enough.
#[test]
fun shed_releases_whole_group() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, vector[30, 20], &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 2, &clock);
    connect(&mut scenario, entity_id, MOD_B, 0, 2, &clock);
    connect(&mut scenario, entity_id, MOD_C, 0, 0, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 10, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_B, 10, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_C, 20, &clock);

    // 50 -> 30: 40 used, dropping A alone would fit, but both A and B go.
    set_generator(&mut scenario, entity_id, 1, false, &clock);
    assert!(shed_modules() == vector[MOD_A, MOD_B]);
    assert!(active(&mut scenario, entity_id, MOD_C) == 20);
    assert!(used(&mut scenario, entity_id) == 20);

    clock.destroy_for_testing();
    scenario.end();
}

/// Grid off drops every reservation in one pass, in connect order.
#[test]
fun power_off_sheds_every_reservation() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, vector[50], &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);
    connect(&mut scenario, entity_id, MOD_B, 0, 3, &clock);
    connect(&mut scenario, entity_id, MOD_C, 0, 1, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 10, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_B, 10, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_C, 10, &clock);

    power(&mut scenario, entity_id, false, &clock);
    assert!(shed_modules() == vector[MOD_A, MOD_B, MOD_C]);
    assert!(used(&mut scenario, entity_id) == 0);

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun shed_nothing_while_it_fits() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, vector[30, 20], &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 1, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 30, &clock);

    set_generator(&mut scenario, entity_id, 1, false, &clock);
    assert!(shed_modules().is_empty());
    assert!(active(&mut scenario, entity_id, MOD_A) == 30);

    clock.destroy_for_testing();
    scenario.end();
}

// === Elastic ===

#[test]
fun elastic_partial_grant() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, vector[50], &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);
    connect(&mut scenario, entity_id, MOD_B, 5, 0, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 30, &clock);

    // Leftover 20, minus 5 line loss: 15 of the 40 asked.
    reserve_elastic(&mut scenario, entity_id, MOD_B, 40, &clock);
    let reserved = event::events_by_type<Reserved>();
    assert!(reserved.length() == 1);
    let (_, module_id, kind, requested, line_loss, active_draw) = reserved[0].reserved_fields();
    assert!(module_id == MOD_B && !kind.is_firm());
    assert!(requested == 40 && line_loss == 5 && active_draw == 15);
    assert!(used(&mut scenario, entity_id) == 50);

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun elastic_full_grant_when_it_fits() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, vector[50], &clock);
    connect(&mut scenario, entity_id, MOD_A, 2, 0, &clock);

    reserve_elastic(&mut scenario, entity_id, MOD_A, 10, &clock);
    assert!(active(&mut scenario, entity_id, MOD_A) == 10);
    assert!(used(&mut scenario, entity_id) == 12);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = grid_load::EInsufficientPower)]
fun elastic_aborts_when_leftover_only_covers_line_loss() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, vector[50], &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);
    connect(&mut scenario, entity_id, MOD_B, 5, 0, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 45, &clock);
    reserve_elastic(&mut scenario, entity_id, MOD_B, 10, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_load::EZeroDraw)]
fun elastic_zero_draw_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, vector[50], &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);
    reserve_elastic(&mut scenario, entity_id, MOD_A, 0, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_load::EAlreadyReserved)]
fun elastic_after_firm_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = powered(&mut scenario, vector[50], &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 10, &clock);
    reserve_elastic(&mut scenario, entity_id, MOD_A, 10, &clock);

    abort
}
